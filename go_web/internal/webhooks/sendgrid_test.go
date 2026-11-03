package webhooks

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"
)

var rubySendgridSignedAt = time.Unix(1792001956, 0)

type sendgridSigner struct {
	keys    []*ecdsa.PrivateKey
	encoded []string
}

func newSendgridSigner(t *testing.T, n int) *sendgridSigner {
	t.Helper()
	signer := &sendgridSigner{}
	for range n {
		key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			t.Fatal(err)
		}
		der, err := x509.MarshalPKIXPublicKey(&key.PublicKey)
		if err != nil {
			t.Fatal(err)
		}
		signer.keys = append(signer.keys, key)
		signer.encoded = append(signer.encoded, base64.StdEncoding.EncodeToString(der))
	}
	return signer
}

func (s *sendgridSigner) sign(t *testing.T, key int, timestamp, body string) string {
	t.Helper()
	digest := sha256.Sum256([]byte(timestamp + body))
	signature, err := ecdsa.SignASN1(rand.Reader, s.keys[key], digest[:])
	if err != nil {
		t.Fatal(err)
	}
	return base64.StdEncoding.EncodeToString(signature)
}

// newSendgridHarness configures one key per signer key.
func newSendgridHarness(t *testing.T, signer *sendgridSigner) *harness {
	h := newHarness(t, func(d *Deps) { d.SendgridPublicKeys = signer.encoded })
	h.now = rubySendgridSignedAt
	return h
}

func postSendgrid(h *harness, path, signature, timestamp, body string) *httptest.ResponseRecorder {
	headers := map[string]string{}
	if signature != "" {
		headers["X-Twilio-Email-Event-Webhook-Signature"] = signature
	}
	if timestamp != "" {
		headers["X-Twilio-Email-Event-Webhook-Timestamp"] = timestamp
	}
	return h.post(path, "application/json", body, headers)
}

func enforceSendgridSignatures(h *harness) {
	h.flags.HSet(sendgridFlag, "boolean", "true")
}

func TestSendgridVerifierAcceptsTheSignatureRubyMakes(t *testing.T) {
	v := newSendgridVerifier([]string{rubySendgridKey1, rubySendgridKey2})
	if reason := v.verify(rubySendgridSignature, rubySendgridTimestamp, []byte(rubySendgridBody), rubySendgridSignedAt); reason != "" {
		t.Fatalf("verify() = %q", reason)
	}
	only := newSendgridVerifier([]string{rubySendgridKey1})
	if reason := only.verify(rubySendgridSignature, rubySendgridTimestamp, []byte(rubySendgridBody), rubySendgridSignedAt); reason != "Invalid signature" {
		t.Fatalf("verify() under the other key = %q", reason)
	}
}

// OpenSSL::PKey::EC.new raises inside the any? loop, before later keys are tried.
func TestSendgridVerifierRaisesOnABadKeyOnceReached(t *testing.T) {
	body := []byte(rubySendgridBody)
	before := newSendgridVerifier([]string{"bm90IGEga2V5", rubySendgridKey2})
	if reason := before.verify(rubySendgridSignature, rubySendgridTimestamp, body, rubySendgridSignedAt); !strings.HasPrefix(reason, "Verification raised: ") {
		t.Errorf("a bad key before the signing one: %q", reason)
	}
	after := newSendgridVerifier([]string{rubySendgridKey2, "bm90IGEga2V5"})
	if reason := after.verify(rubySendgridSignature, rubySendgridTimestamp, body, rubySendgridSignedAt); reason != "" {
		t.Errorf("a bad key after the signing one: %q", reason)
	}
}

func TestSendgridVerifierFailureMessages(t *testing.T) {
	signer := newSendgridSigner(t, 1)
	v := newSendgridVerifier(signer.encoded)
	now := rubySendgridSignedAt
	ts := strconv.FormatInt(now.Unix(), 10)
	old := strconv.FormatInt(now.Add(-6*time.Minute).Unix(), 10)
	body := `[{"event":"delivered"}]`
	cases := map[string]struct {
		signature, timestamp, body string
		want                       string
	}{
		"missing signature": {"", ts, body, "Missing signature"},
		"blank signature":   {" ", ts, body, "Missing signature"},
		"missing timestamp": {signer.sign(t, 0, ts, body), "", body, "Missing timestamp"},
		"old timestamp":     {signer.sign(t, 0, old, body), old, body, "Timestamp too old"},
		"tampered payload":  {signer.sign(t, 0, ts, body), ts, `[{"event":"tampered"}]`, "Invalid signature"},
		"not base64":        {"!!!", ts, body, "Invalid signature"},
	}
	for name, tc := range cases {
		if got := v.verify(tc.signature, tc.timestamp, []byte(tc.body), now); got != tc.want {
			t.Errorf("%s: verify() = %q, want %q", name, got, tc.want)
		}
	}
	if got := newSendgridVerifier(nil).verify("x", ts, []byte(body), now); got != "No public keys configured" {
		t.Errorf("verify() without keys = %q", got)
	}
}

func TestSendgridWebhookEnqueuesTheParamsRailsBuilds(t *testing.T) {
	signer := newSendgridSigner(t, 3)
	for name, tc := range railsSendgridParams {
		h := newSendgridHarness(t, signer)
		enforceSendgridSignatures(h)
		rec := postSendgrid(h, "/sendgrid-webhook"+tc.query, signer.sign(t, 2, rubySendgridTimestamp, tc.body), rubySendgridTimestamp, tc.body)
		payloads, args := h.pushed(t, "low")
		if rec.Code != http.StatusOK || rec.Body.String() != successJSON || len(args) != 1 {
			t.Fatalf("%s: got %d %s, pushed %d", name, rec.Code, rec.Body, len(args))
		}
		if args[0] != tc.args {
			t.Errorf("%s: arg = %s\nwant  %s", name, args[0], tc.args)
		}
		if !strings.HasPrefix(payloads[0], `{"retry":5,"queue":"low","backtrace":true,"args":[`) || !strings.Contains(payloads[0], `"class":"HandleSendgridEventJob"`) {
			t.Errorf("%s: payload = %s", name, payloads[0])
		}
	}
}

func TestSendgridWebhookWithTheFlagOnRejectsWhatFailsVerification(t *testing.T) {
	signer := newSendgridSigner(t, 1)
	other := newSendgridSigner(t, 1)
	ts, body := rubySendgridTimestamp, rubySendgridBody
	for name, headers := range map[string][2]string{
		"missing signature": {"", ts},
		"missing timestamp": {signer.sign(t, 0, ts, body), ""},
		"unrelated key":     {other.sign(t, 0, ts, body), ts},
	} {
		h := newSendgridHarness(t, signer)
		enforceSendgridSignatures(h)
		rec := postSendgrid(h, "/sendgrid-webhook", headers[0], headers[1], body)
		if _, args := h.pushed(t, "low"); rec.Code != http.StatusInternalServerError || rec.Body.String() != failureJSON || len(args) != 0 {
			t.Errorf("%s: got %d %s, pushed %d", name, rec.Code, rec.Body, len(args))
		}
		if !strings.Contains(h.logs.String(), "SendGrid webhook verification failed: ") || !strings.Contains(h.logs.String(), "Error verifying SendGrid webhook: ") {
			t.Errorf("%s: logs = %s", name, h.logs.String())
		}
	}
}

func TestSendgridWebhookWithTheFlagOffStillEnqueues(t *testing.T) {
	signer := newSendgridSigner(t, 1)
	ts, body := rubySendgridTimestamp, rubySendgridBody
	for name, headers := range map[string][2]string{
		"valid":           {signer.sign(t, 0, ts, body), ts},
		"unsigned":        {"", ts},
		"unsigned legacy": {"", ""},
	} {
		h := newSendgridHarness(t, signer)
		before := h.flags.CommandCount()
		rec := postSendgrid(h, "/sendgrid-webhook", headers[0], headers[1], body)
		if _, args := h.pushed(t, "low"); rec.Code != http.StatusOK || len(args) != 1 {
			t.Errorf("%s: got %d %s, pushed %d", name, rec.Code, rec.Body, len(args))
		}
		// The flag is only read once a check fails.
		if reads := h.flags.CommandCount() - before; (reads > 0) != (name != "valid") {
			t.Errorf("%s: %d flag reads", name, reads)
		}
	}
}

// RedisFailOpen raises on a flag it has never read, and rescue_from answers head 503.
func TestSendgridWebhookAnswers503WhenTheFlagIsUnavailable(t *testing.T) {
	h := newSendgridHarness(t, newSendgridSigner(t, 1))
	h.flags.SetError("ERR timeout")
	rec := postSendgrid(h, "/sendgrid-webhook", "", rubySendgridTimestamp, rubySendgridBody)
	if _, args := h.pushed(t, "low"); rec.Code != http.StatusServiceUnavailable || rec.Body.Len() != 0 || len(args) != 0 {
		t.Fatalf("got %d %q, pushed %d", rec.Code, rec.Body, len(args))
	}
}

func TestSendgridWebhookAnswers503WhenRedisFails(t *testing.T) {
	signer := newSendgridSigner(t, 1)
	h := newSendgridHarness(t, signer)
	h.jobs.SetError("ERR connection lost")
	rec := postSendgrid(h, "/sendgrid-webhook", signer.sign(t, 0, rubySendgridTimestamp, rubySendgridBody), rubySendgridTimestamp, rubySendgridBody)
	if rec.Code != http.StatusServiceUnavailable || rec.Body.Len() != 0 {
		t.Fatalf("got %d %q", rec.Code, rec.Body)
	}
}

// ParamsWrapper swallows the ParseError, so the filter runs first; the action's params
// then raise it again, and with no public/400.html the exceptions app sends an empty 400.
func TestSendgridWebhookParsesTheParamsAfterVerification(t *testing.T) {
	signer := newSendgridSigner(t, 1)
	for name, body := range map[string]string{
		"truncated":                 `[{"event":`,
		"lone high surrogate":       `[{"event":"\ud800"}]`,
		"past JSON.parse's nesting": strings.Repeat("[", 101) + "1" + strings.Repeat("]", 101),
	} {
		h := newSendgridHarness(t, signer)
		rec := postSendgrid(h, "/sendgrid-webhook", "", "", body)
		if _, args := h.pushed(t, "low"); rec.Code != http.StatusBadRequest || rec.Body.Len() != 0 || rec.Header().Get("Content-Type") != "text/html; charset=utf-8" || len(args) != 0 {
			t.Errorf("%s: got %d %q %q, pushed %d", name, rec.Code, rec.Header().Get("Content-Type"), rec.Body, len(args))
		}

		h = newSendgridHarness(t, signer)
		enforceSendgridSignatures(h)
		if rec := postSendgrid(h, "/sendgrid-webhook", "", "", body); rec.Code != http.StatusInternalServerError {
			t.Errorf("%s with the flag on: got %d, want the filter's 500 first", name, rec.Code)
		}
	}
}

// ActionDispatch refuses this body before any filter, so the flag is never read.
func TestSendgridWebhookRejectsAnUnpairedLowSurrogateFirst(t *testing.T) {
	h := newSendgridHarness(t, newSendgridSigner(t, 1))
	enforceSendgridSignatures(h)
	before := h.flags.CommandCount()
	rec := postSendgrid(h, "/sendgrid-webhook", "", "", `[{"event":"\udc00"}]`)
	if rec.Code != http.StatusBadRequest || h.flags.CommandCount() != before {
		t.Fatalf("got %d %q, %d flag reads", rec.Code, rec.Body, h.flags.CommandCount()-before)
	}
}

func TestSendgridSignatureCoversTheSanitizedBody(t *testing.T) {
	signer := newSendgridSigner(t, 1)
	sent := `[{"email":"` + "\xff" + `@example.com"}]`
	sanitized := `[{"email":"` + "\uFFFD" + `@example.com"}]`
	h := newSendgridHarness(t, signer)
	enforceSendgridSignatures(h)
	rec := postSendgrid(h, "/sendgrid-webhook", signer.sign(t, 0, rubySendgridTimestamp, sanitized), rubySendgridTimestamp, sent)
	if _, args := h.pushed(t, "low"); rec.Code != http.StatusOK || len(args) != 1 || !strings.Contains(args[0], "\uFFFD@example.com") {
		t.Fatalf("got %d %s, pushed %v", rec.Code, rec.Body, args)
	}
}

// An expression gate can't be read as off, so an unsigned event gets the unknown flag's 503.
func TestSendgridWebhookAnswers503ForAnExpressionGate(t *testing.T) {
	h := newSendgridHarness(t, newSendgridSigner(t, 1))
	h.flags.HSet(sendgridFlag, "expression", `{"Equal":[{"Property":["plan"]},"basic"]}`)
	rec := postSendgrid(h, "/sendgrid-webhook", "", rubySendgridTimestamp, rubySendgridBody)
	if _, args := h.pushed(t, "low"); rec.Code != http.StatusServiceUnavailable || rec.Body.Len() != 0 || len(args) != 0 {
		t.Fatalf("got %d %q, pushed %d", rec.Code, rec.Body, len(args))
	}
}
