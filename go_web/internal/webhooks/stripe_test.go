package webhooks

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
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

func postStripe(h *harness, path, header, body string) *httptest.ResponseRecorder {
	return h.post(path, "application/json; charset=utf-8", body, map[string]string{"Stripe-Signature": header})
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
	h := newHarness(t, nil)
	rec := postStripe(h, "/stripe-webhook", rubyStripeHeader, rubyStripePayload)
	if rec.Code != http.StatusOK || rec.Body.String() != successJSON || rec.Header().Get("Content-Type") != "application/json; charset=utf-8" {
		t.Fatalf("got %d %q %s", rec.Code, rec.Header().Get("Content-Type"), rec.Body)
	}
	// render json: goes through Rack::ETag.
	if rec.Header().Get("ETag") == "" || rec.Header().Get("Cache-Control") != "max-age=0, private, must-revalidate" {
		t.Errorf("headers = %v", rec.Header())
	}
	payloads, args := h.pushed(t, "default")
	if len(args) != 1 || args[0] != rubyStripeAsJSON {
		t.Fatalf("arg = %v\nwant %s", args, rubyStripeAsJSON)
	}
	if !strings.HasPrefix(payloads[0], `{"retry":10,"queue":"default","backtrace":true,"args":[`) || !strings.Contains(payloads[0], `,"class":"HandleStripeEventWorker","jid":"`) {
		t.Fatalf("payload = %s", payloads[0])
	}
}

func TestStripeWebhookRejections(t *testing.T) {
	body := `{"type":"charge.succeeded","id":"evt_dafasdfadsf","pending_webhooks":"0","user_id":"1"}`
	for name, header := range map[string]string{
		"invalid signature": "invalid",
		"missing header":    "",
		"tampered body":     stripeHeader(body+" ", rubyStripeSignedAt),
	} {
		h := newHarness(t, nil)
		rec := postStripe(h, "/stripe-webhook", header, body)
		if _, args := h.pushed(t, "default"); rec.Code != http.StatusBadRequest || rec.Body.String() != failureJSON || len(args) != 0 {
			t.Errorf("%s: got %d %s, pushed %d", name, rec.Code, rec.Body, len(args))
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
		"charge.succeeded":       {"/stripe-webhook", `{"type":"charge.succeeded","id":"evt_1","user_id":"1"}`, 200, successJSON, true},
		"no id":                  {"/stripe-webhook", `{"type":"charge.succeeded"}`, 200, failureJSON, false},
		"false id":               {"/stripe-webhook", `{"id":false}`, 200, failureJSON, false},
		"empty id is truthy":     {"/stripe-webhook", `{"id":""}`, 200, successJSON, true},
		"Infinity id is truthy":  {"/stripe-webhook", `{"id":1e400}`, 200, successJSON, true},
		"not JSON":               {"/stripe-webhook", `{"id":`, 400, failureJSON, false},
		"lone high surrogate":    {"/stripe-webhook", `{"id":"\ud800"}`, 400, failureJSON, false},
		"connect with user_id":   {"/stripe-connect-webhook", `{"type":"transfer.paid","id":"evt_1","user_id":"acct_1234"}`, 200, successJSON, true},
		"connect with account":   {"/stripe-connect-webhook", `{"id":"evt_1","account":"acct_1234"}`, 200, successJSON, true},
		"connect, empty object":  {"/stripe-connect-webhook", `{"id":"evt_1","account":{}}`, 200, successJSON, true},
		"connect, no account":    {"/stripe-connect-webhook", `{"id":"evt_1"}`, 200, failureJSON, false},
		"connect, blank account": {"/stripe-connect-webhook", `{"id":"evt_1","account":"\u00a0"}`, 200, failureJSON, false},
		"connect, blank id":      {"/stripe-connect-webhook", `{"id":" ","account":"acct_1"}`, 200, failureJSON, false},
		"connect, empty list":    {"/stripe-connect-webhook", `{"id":"evt_1","user_id":[]}`, 200, failureJSON, false},
	}
	for name, tc := range cases {
		h := newHarness(t, nil)
		rec := postStripe(h, tc.path, stripeHeader(tc.body, rubyStripeSignedAt), tc.body)
		if _, args := h.pushed(t, "default"); rec.Code != tc.status || rec.Body.String() != tc.response || (len(args) == 1) != tc.enqueued {
			t.Errorf("%s: got %d %s, pushed %d", name, rec.Code, rec.Body, len(args))
		}
	}
}

// Stripe::Event.construct_from and Util.secure_compare raise, and the exceptions app
// renders public/500.html.
func TestStripeWebhookRendersTheErrorPageWhereRailsRaises(t *testing.T) {
	signature := strings.TrimPrefix(stripeHeader(`[]`, rubyStripeSignedAt), fmt.Sprintf("t=%d,", rubyStripeTimestamp))
	for name, tc := range map[string][2]string{
		"array body": {stripeHeader(`[]`, rubyStripeSignedAt), `[]`},
		"bare v1":    {fmt.Sprintf("t=%d,v1,%s", rubyStripeTimestamp, signature), `[]`},
	} {
		h := newHarness(t, nil)
		rec := postStripe(h, "/stripe-webhook", tc[0], tc[1])
		if rec.Code != http.StatusInternalServerError || !strings.Contains(rec.Body.String(), "<html") {
			t.Errorf("%s: got %d %.80q", name, rec.Code, rec.Body)
		}
	}
}

func TestStripeWebhookAnswers503SoStripeRedeliversWhenRedisFails(t *testing.T) {
	h := newHarness(t, nil)
	h.jobs.SetError("ERR connection lost")
	body := `{"type":"charge.succeeded","id":"evt_1"}`
	rec := postStripe(h, "/stripe-webhook", stripeHeader(body, rubyStripeSignedAt), body)
	if rec.Code != http.StatusServiceUnavailable || rec.Body.Len() != 0 {
		t.Fatalf("got %d %q, want head :service_unavailable", rec.Code, rec.Body)
	}
}

// Rails checks the signature over raw_post, which Rack::UTF8Sanitizer has already rewritten.
func TestStripeSignatureCoversTheSanitizedBody(t *testing.T) {
	invalid := `{"id":"evt_1","name":"` + "\xff" + `"}`
	sanitized := `{"id":"evt_1","name":"` + "\uFFFD" + `"}`
	cases := map[string]struct {
		body, signedOver string
		status           int
	}{
		"signed over the bytes sent":     {invalid, invalid, http.StatusBadRequest},
		"signed over the sanitized body": {invalid, sanitized, http.StatusOK},
		"byte order mark":                {"\xef\xbb\xbf{\"id\":\"evt_1\"}", `{"id":"evt_1"}`, http.StatusOK},
	}
	for name, tc := range cases {
		h := newHarness(t, nil)
		if rec := postStripe(h, "/stripe-webhook", stripeHeader(tc.signedOver, rubyStripeSignedAt), tc.body); rec.Code != tc.status {
			t.Errorf("%s: got %d %s", name, rec.Code, rec.Body)
		}
	}
}

// Outside a JSON request ActionDispatch never parses the body, so Sidekiq's
// JSON.generate is what refuses the string an unpaired low surrogate leaves.
func TestStripeWebhookFailsWhereSidekiqCannotSerializeTheEvent(t *testing.T) {
	h := newHarness(t, nil)
	body := `{"id":"evt_1","s":"\udc00"}`
	rec := h.post("/stripe-webhook", "text/plain", body, map[string]string{"Stripe-Signature": stripeHeader(body, rubyStripeSignedAt)})
	if _, args := h.pushed(t, "default"); rec.Code != http.StatusInternalServerError || len(args) != 0 {
		t.Fatalf("got %d, pushed %d", rec.Code, len(args))
	}
}

func TestStripeAsJSONOrdersAndConvertsLikeStripeObject(t *testing.T) {
	parsed, _, err := parseJSON([]byte(`{"a":[1,null,{"x":1,"id":"ch_1"}],"id":"evt_1","b":{"c":-1e400,"d":1.50,"id":null}}`))
	if err != nil {
		t.Fatal(err)
	}
	got, err := sidekiqMarshal(stripeAsJSON(parsed))
	if want := `{"id":"evt_1","a":[1,null,{"id":"ch_1","x":1}],"b":{"c":null,"d":1.5,"id":null}}`; err != nil || got != want {
		t.Fatalf("stripeAsJSON = %s, %v; want %s", got, err, want)
	}
}
