package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"
)

var rubyStripeSignedAt = time.Unix(rubyStripeTimestamp, 0)

func stripeHeader(body string, at time.Time) string {
	mac := hmac.New(sha256.New, []byte(rubyStripeSecret))
	fmt.Fprintf(mac, "%d.%s", at.Unix(), body)
	return fmt.Sprintf("t=%d,v1=%s", at.Unix(), hex.EncodeToString(mac.Sum(nil)))
}

func newStripeTestServer(t *testing.T, queue enqueuer) *server {
	s := newTestServer(t, queue)
	s.stripe = newStripeVerifier(rubyStripeSecret)
	s.stripeConnect = newStripeVerifier(rubyStripeSecret)
	s.now = func() time.Time { return rubyStripeSignedAt }
	return s
}

func postStripe(s *server, path, header, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodPost, path, strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json; charset=utf-8")
	if header != "" {
		req.Header.Set("Stripe-Signature", header)
	}
	rec := httptest.NewRecorder()
	s.routes().ServeHTTP(rec, req)
	return rec
}

func TestStripeVerifierAcceptsTheHeaderRubyGenerates(t *testing.T) {
	v := newStripeVerifier(rubyStripeSecret)
	if err := v.verify(rubyStripeHeader, []byte(rubyStripePayload), rubyStripeSignedAt.Add(299*time.Second)); err != nil {
		t.Fatalf("verify() = %v", err)
	}
	// Only the past is bounded.
	if err := v.verify(rubyStripeHeader, []byte(rubyStripePayload), rubyStripeSignedAt.Add(-time.Hour)); err != nil {
		t.Fatalf("verify() with a future timestamp = %v", err)
	}
}

func TestStripeVerifierFollowsVerifyHeader(t *testing.T) {
	v := newStripeVerifier(rubyStripeSecret)
	signature := strings.TrimPrefix(rubyStripeHeader, fmt.Sprintf("t=%d,", rubyStripeTimestamp))
	accepted := map[string]string{
		"rotated secret, second v1":  fmt.Sprintf("t=%d,v1=00, %s", rubyStripeTimestamp, signature),
		"other schemes ignored":      fmt.Sprintf("t=%d,v0=00,%s", rubyStripeTimestamp, signature),
		"first t wins":               fmt.Sprintf("t=%d,t=1,%s", rubyStripeTimestamp, signature),
		"Integer() reads hex":        fmt.Sprintf("t=0x%x,%s", rubyStripeTimestamp, signature),
		"whitespace around t":        fmt.Sprintf("t= %d ,%s", rubyStripeTimestamp, signature),
		"trailing separator dropped": fmt.Sprintf("t=%d,%s,", rubyStripeTimestamp, signature),
	}
	for name, header := range accepted {
		if err := v.verify(header, []byte(rubyStripePayload), rubyStripeSignedAt); err != nil {
			t.Errorf("%s: verify(%q) = %v", name, header, err)
		}
	}
	rejected := map[string]string{
		"missing header":     "",
		"no timestamp":       signature,
		"bare t":             "t," + signature,
		"float timestamp":    "t=1.5," + signature,
		"no v1":              fmt.Sprintf("t=%d", rubyStripeTimestamp),
		"wrong signature":    fmt.Sprintf("t=%d,v1=%s", rubyStripeTimestamp, strings.Repeat("0", 64)),
		"uppercase hex":      fmt.Sprintf("t=%d,v1=%s", rubyStripeTimestamp, strings.ToUpper(strings.TrimPrefix(signature, "v1="))),
		"leading space on t": fmt.Sprintf(" t=%d,%s", rubyStripeTimestamp, signature),
	}
	for name, header := range rejected {
		err := v.verify(header, []byte(rubyStripePayload), rubyStripeSignedAt)
		if err == nil || errors.Is(err, errRailsRaises) {
			t.Errorf("%s: verify(%q) = %v, want a SignatureVerificationError", name, header, err)
		}
	}
	if err := v.verify(rubyStripeHeader, []byte(rubyStripePayload), rubyStripeSignedAt.Add(301*time.Second)); err == nil {
		t.Error("a timestamp past the tolerance was accepted")
	}
	// Util.secure_compare(expected, nil) raises before any later entry is compared.
	bare := fmt.Sprintf("t=%d,v1,%s", rubyStripeTimestamp, signature)
	if err := v.verify(bare, []byte(rubyStripePayload), rubyStripeSignedAt); !errors.Is(err, errRailsRaises) {
		t.Errorf("verify(%q) = %v, want it to raise", bare, err)
	}
}

func TestStripeWebhookEnqueuesWhatAsJSONYields(t *testing.T) {
	queue := &fakeQueue{}
	rec := postStripe(newStripeTestServer(t, queue), "/stripe-webhook", rubyStripeHeader, rubyStripePayload)
	if rec.Code != http.StatusOK || rec.Body.String() != `{"success":true}` {
		t.Fatalf("got %d %s", rec.Code, rec.Body)
	}
	if len(queue.jobs) != 1 || queue.jobs[0].job != stripeJob || queue.jobs[0].delay != 0 {
		t.Fatalf("pushed %+v", queue.jobs)
	}
	if got, want := roundTrip(t, queue.jobs[0].arg), decodeJSON(t, rubyStripeAsJSON); !reflect.DeepEqual(got, want) {
		t.Fatalf("arg = %v\nwant %v", got, want)
	}
}

func TestStripeWebhookRejections(t *testing.T) {
	body := `{"type":"charge.succeeded","id":"evt_dafasdfadsf","pending_webhooks":"0","user_id":"1"}`
	cases := map[string]string{
		"invalid signature": "invalid",
		"missing header":    "",
		"tampered body":     stripeHeader(body+" ", rubyStripeSignedAt),
	}
	for name, header := range cases {
		queue := &fakeQueue{}
		rec := postStripe(newStripeTestServer(t, queue), "/stripe-webhook", header, body)
		if rec.Code != http.StatusBadRequest || rec.Body.String() != `{"success":false}` || len(queue.jobs) != 0 {
			t.Errorf("%s: got %d %s, pushed %d", name, rec.Code, rec.Body, len(queue.jobs))
		}
	}
}

func TestStripeWebhookAnswersTheWayTheControllerDoes(t *testing.T) {
	cases := map[string]struct {
		path, body string
		status     int
		response   string
		enqueued   bool
	}{
		"charge.succeeded":       {"/stripe-webhook", `{"type":"charge.succeeded","id":"evt_1","user_id":"1"}`, 200, `{"success":true}`, true},
		"no id":                  {"/stripe-webhook", `{"type":"charge.succeeded"}`, 200, `{"success":false}`, false},
		"false id":               {"/stripe-webhook", `{"id":false}`, 200, `{"success":false}`, false},
		"empty id is truthy":     {"/stripe-webhook", `{"id":""}`, 200, `{"success":true}`, true},
		"Infinity id is truthy":  {"/stripe-webhook", `{"id":1e400}`, 200, `{"success":true}`, true},
		"not JSON":               {"/stripe-webhook", `{"id":`, 400, `{"success":false}`, false},
		"array body raises":      {"/stripe-webhook", `[{"id":"evt_1"}]`, 500, `{"success":false}`, false},
		"connect with user_id":   {"/stripe-connect-webhook", `{"type":"transfer.paid","id":"evt_1","user_id":"acct_1234"}`, 200, `{"success":true}`, true},
		"connect with account":   {"/stripe-connect-webhook", `{"id":"evt_1","account":"acct_1234"}`, 200, `{"success":true}`, true},
		"connect, empty object":  {"/stripe-connect-webhook", `{"id":"evt_1","account":{}}`, 200, `{"success":true}`, true},
		"connect, no account":    {"/stripe-connect-webhook", `{"id":"evt_1"}`, 200, `{"success":false}`, false},
		"connect, blank account": {"/stripe-connect-webhook", `{"id":"evt_1","account":" "}`, 200, `{"success":false}`, false},
		"connect, blank id":      {"/stripe-connect-webhook", `{"id":" ","account":"acct_1"}`, 200, `{"success":false}`, false},
		"connect, empty list":    {"/stripe-connect-webhook", `{"id":"evt_1","user_id":[]}`, 200, `{"success":false}`, false},
	}
	for name, tc := range cases {
		queue := &fakeQueue{}
		rec := postStripe(newStripeTestServer(t, queue), tc.path, stripeHeader(tc.body, rubyStripeSignedAt), tc.body)
		if rec.Code != tc.status || rec.Body.String() != tc.response || (len(queue.jobs) == 1) != tc.enqueued {
			t.Errorf("%s: got %d %s, pushed %d", name, rec.Code, rec.Body, len(queue.jobs))
		}
	}
}

func TestStripeWebhookAnswers503SoStripeRedeliversWhenRedisFails(t *testing.T) {
	body := `{"type":"charge.succeeded","id":"evt_1"}`
	rec := postStripe(newStripeTestServer(t, &fakeQueue{err: errors.New("connection refused")}), "/stripe-webhook", stripeHeader(body, rubyStripeSignedAt), body)
	if rec.Code != http.StatusServiceUnavailable || rec.Body.Len() != 0 {
		t.Fatalf("got %d %q, want head :service_unavailable", rec.Code, rec.Body)
	}
}

// ActionDispatch rejects a JSON body that isn't UTF-8 before the signature is checked;
// with a non-JSON content type, Sidekiq's JSON.generate raises on it instead.
func TestStripeWebhookOnABodyThatIsNotUTF8(t *testing.T) {
	body := `{"id":"evt_1","name":"` + "\xff" + `"}`
	rec := postStripe(newStripeTestServer(t, &fakeQueue{}), "/stripe-webhook", "invalid", body)
	if rec.Code != http.StatusBadRequest {
		t.Errorf("JSON content type: got %d", rec.Code)
	}

	queue := &fakeQueue{}
	req := httptest.NewRequest(http.MethodPost, "/stripe-webhook", strings.NewReader(body))
	req.Header.Set("Stripe-Signature", stripeHeader(body, rubyStripeSignedAt))
	rec = httptest.NewRecorder()
	newStripeTestServer(t, queue).routes().ServeHTTP(rec, req)
	if rec.Code != http.StatusInternalServerError || len(queue.jobs) != 0 {
		t.Errorf("no content type: got %d, pushed %d", rec.Code, len(queue.jobs))
	}
}

func TestStripeAsJSONKeepsWhatParamsWouldDrop(t *testing.T) {
	parsed, err := (&requestBody{raw: []byte(`{"a":[1,null],"b":{"c":-1e400,"d":1.50,"e":12345678901234567890}}`)}).parseRuby()
	if err != nil {
		t.Fatal(err)
	}
	got, _ := json.Marshal(stripeAsJSON(parsed))
	if want := `{"a":[1,null],"b":{"c":null,"d":1.50,"e":12345678901234567890}}`; string(got) != want {
		t.Fatalf("stripeAsJSON = %s, want %s", got, want)
	}
}
