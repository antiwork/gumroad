package main

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"
)

type pushedJob struct {
	job   jobSpec
	arg   any
	delay time.Duration
}

type fakeQueue struct {
	jobs   []pushedJob
	events []map[string]any
	err    error
}

func (q *fakeQueue) enqueue(_ context.Context, job jobSpec, arg any, delay time.Duration) error {
	if q.err != nil {
		return q.err
	}
	q.jobs = append(q.jobs, pushedJob{job, arg, delay})
	if event, ok := arg.(map[string]any); ok {
		q.events = append(q.events, event)
	}
	return nil
}

func newTestServer(t *testing.T, queue enqueuer) *server {
	t.Helper()
	verifier, err := newSignatureVerifier(testWebhookSecret)
	if err != nil {
		t.Fatal(err)
	}
	return &server{
		resend: verifier,
		filter: newEventFilter(testHeaderKey),
		queue:  queue,
		logger: slog.New(slog.NewTextHandler(io.Discard, nil)),
		now:    func() time.Time { return testSignedAt },
	}
}

func post(s *server, signature, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodPost, "/resend-webhook", strings.NewReader(body))
	req.Header = signedHeader(signature)
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	s.routes().ServeHTTP(rec, req)
	return rec
}

func TestResendWebhookAcknowledgesAnUntrackedEventWithoutEnqueueing(t *testing.T) {
	queue := &fakeQueue{}
	s := newTestServer(t, queue)
	body, _ := json.Marshal(eventWithHeaders("email.sent", [2]string{"X-Gum-Mailer-Class", encryptedClass}))
	rec := post(s, "v1,"+sign(t, s.resend, body), string(body))
	if rec.Code != http.StatusOK || rec.Body.String() != `{"success":true}` {
		t.Fatalf("got %d %s", rec.Code, rec.Body)
	}
	if len(queue.events) != 0 {
		t.Fatalf("enqueued %d events", len(queue.events))
	}
}

// testPayload has no data.created_at, so ResendEventInfo.new raises and Rails enqueues it.
func TestResendWebhookEnqueuesAnEventRailsCouldNotParse(t *testing.T) {
	queue := &fakeQueue{}
	rec := post(newTestServer(t, queue), "v1,"+testSignature, testPayload)
	if rec.Code != http.StatusOK || len(queue.events) != 1 {
		t.Fatalf("got %d, enqueued %d", rec.Code, len(queue.events))
	}
}

func TestResendWebhookEnqueuesATrackedEvent(t *testing.T) {
	queue := &fakeQueue{}
	s := newTestServer(t, queue)
	body, _ := json.Marshal(eventWithHeaders("email.delivered",
		[2]string{"X-Gum-Mailer-Class", encryptedClass},
		[2]string{"X-Gum-Mailer-Method", encryptedMethod},
	))
	rec := post(s, "v1,"+sign(t, s.resend, body), string(body))
	if rec.Code != http.StatusOK {
		t.Fatalf("got %d %s", rec.Code, rec.Body)
	}
	if len(queue.events) != 1 || queue.events[0]["action"] != "resend" || queue.events[0]["type"] != "email.delivered" {
		t.Fatalf("enqueued %v", queue.events)
	}
}

func TestResendWebhookRejectsABadSignature(t *testing.T) {
	queue := &fakeQueue{}
	rec := post(newTestServer(t, queue), "v1,"+testSignature, testPayload+" ")
	if rec.Code != http.StatusBadRequest || rec.Body.String() != `{"success":false}` {
		t.Fatalf("got %d %s", rec.Code, rec.Body)
	}
	if len(queue.events) != 0 {
		t.Fatalf("enqueued %d events", len(queue.events))
	}
}

func TestResendWebhookRefusesAnOversizedBodyBeforeReadingIt(t *testing.T) {
	queue := &fakeQueue{}
	rec := post(newTestServer(t, queue), "v1,"+testSignature, strings.Repeat("x", maxBodyBytes+1))
	if rec.Code != http.StatusRequestEntityTooLarge || len(queue.events) != 0 {
		t.Fatalf("got %d, enqueued %d", rec.Code, len(queue.events))
	}
}

func TestResendWebhookAsksResendToRetryWhenRedisFails(t *testing.T) {
	s := newTestServer(t, &fakeQueue{err: errors.New("connection refused")})
	body, _ := json.Marshal(eventWithHeaders("email.delivered",
		[2]string{"X-Gum-Mailer-Class", encryptedClass},
		[2]string{"X-Gum-Mailer-Method", encryptedMethod},
	))
	rec := post(s, "v1,"+sign(t, s.resend, body), string(body))
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("got %d, want 500 so Resend retries", rec.Code)
	}
}

func TestHealthcheck(t *testing.T) {
	rec := httptest.NewRecorder()
	newTestServer(t, &fakeQueue{}).routes().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/healthcheck", nil))
	if rec.Code != http.StatusOK || rec.Body.String() != "healthcheck" {
		t.Fatalf("got %d %s", rec.Code, rec.Body)
	}
}

func TestRoutesWithoutTheirSecretsAreNotServed(t *testing.T) {
	s := newTestServer(t, &fakeQueue{})
	for _, path := range []string{"/stripe-webhook", "/stripe-connect-webhook", "/sendgrid-webhook", "/sns-mediaconvert-webhook", "/paypal-webhook", "/grmc-webhook"} {
		rec := httptest.NewRecorder()
		s.routes().ServeHTTP(rec, httptest.NewRequest(http.MethodPost, path, bytes.NewReader(nil)))
		if rec.Code != http.StatusNotFound {
			t.Errorf("%s: got %d", path, rec.Code)
		}
	}
}

func clearOptionalEnv(t *testing.T) {
	for _, name := range append([]string{"STRIPE__ENDPOINT_SECRET", "STRIPE_CONNECT__ENDPOINT_SECRET", "REDIS_HOST"}, sendgridPublicKeyEnvVars...) {
		t.Setenv(name, "")
	}
}

func TestConfigureOptionalRoutesFollowsTheEnvironment(t *testing.T) {
	clearOptionalEnv(t)
	var logs bytes.Buffer
	logger := slog.New(slog.NewJSONHandler(&logs, nil))

	s := &server{}
	configureOptionalRoutes(s, logger)
	if s.stripe != nil || s.stripeConnect != nil || s.sendgrid != nil {
		t.Fatal("a route without its secret was turned on")
	}
	for _, want := range []string{"/stripe-webhook is off", "/stripe-connect-webhook is off", "/sendgrid-webhook is off"} {
		if strings.Count(logs.String(), want) != 1 {
			t.Errorf("want one warning containing %q in %s", want, logs.String())
		}
	}

	t.Setenv("STRIPE__ENDPOINT_SECRET", "whsec_x")
	t.Setenv("STRIPE_CONNECT__ENDPOINT_SECRET", "<no value>")
	t.Setenv(sendgridPublicKeyEnvVars[1], rubySendgridKey2)
	t.Setenv(sendgridPublicKeyEnvVars[3], " ")
	t.Setenv("REDIS_HOST", "127.0.0.1:6379")
	s = &server{}
	client := configureOptionalRoutes(s, logger)
	if client == nil {
		t.Fatal("no flag client")
	}
	defer client.Close()
	if s.stripe == nil || s.stripeConnect != nil || s.sendgrid == nil || len(s.sendgrid.keys) != 1 || s.sendgridFlag == nil {
		t.Fatalf("stripe %v, connect %v, sendgrid %+v", s.stripe != nil, s.stripeConnect != nil, s.sendgrid)
	}
}

// RedisFailOpen raises on a flag it has never read, so without its Redis the route
// would only ever answer 503 to an unsigned event.
func TestSendgridNeedsTheFlagRedis(t *testing.T) {
	for name, host := range map[string]string{"unset": "", "unparseable": "127.0.0.1:notaport"} {
		clearOptionalEnv(t)
		t.Setenv(sendgridPublicKeyEnvVars[0], rubySendgridKey2)
		t.Setenv("REDIS_HOST", host)
		var logs bytes.Buffer
		s := &server{}
		if client := configureOptionalRoutes(s, slog.New(slog.NewJSONHandler(&logs, nil))); client != nil {
			client.Close()
			t.Errorf("%s: got a flag client", name)
		}
		if s.sendgrid != nil || !strings.Contains(logs.String(), "/sendgrid-webhook is off") {
			t.Errorf("%s: sendgrid on %v, logs %s", name, s.sendgrid != nil, logs.String())
		}
	}
}

func countLines(t *testing.T, logs *bytes.Buffer) map[string]map[string]any {
	t.Helper()
	lines := map[string]map[string]any{}
	for _, raw := range bytes.Split(bytes.TrimSpace(logs.Bytes()), []byte("\n")) {
		var line map[string]any
		if err := json.Unmarshal(raw, &line); err != nil {
			t.Fatal(err)
		}
		if msg := line["msg"].(string); strings.HasSuffix(msg, " webhooks") {
			delete(line, "time")
			delete(line, "level")
			delete(line, "msg")
			lines[msg] = line
		}
	}
	return lines
}

func TestLogCountsKeepsResendsLineAndGivesEachRouteItsOwn(t *testing.T) {
	var logs bytes.Buffer
	s := newStripeTestServer(t, &fakeQueue{})
	s.logger = slog.New(slog.NewJSONHandler(&logs, nil))
	body := `{"id":"evt_1"}`
	postStripe(s, "/stripe-webhook", stripeHeader(body, rubyStripeSignedAt), body)
	postStripe(s, "/stripe-webhook", "invalid", body)
	post(s, "v1,"+testSignature, testPayload)
	s.logCounts()

	lines := countLines(t, &logs)
	resend := lines["resend webhooks"]
	if want := map[string]any{"received": 1.0, "enqueued": 1.0, "filtered": 0.0, "rejected": 0.0, "malformed": 0.0, "failed": 0.0}; !reflect.DeepEqual(resend, want) {
		t.Errorf("resend line = %v, want %v", resend, want)
	}
	stripe := lines["stripe webhooks"]
	if stripe["received"] != 2.0 || stripe["enqueued"] != 1.0 || stripe["rejected"] != 1.0 || stripe["failed"] != 0.0 {
		t.Errorf("stripe line = %v", stripe)
	}
	if _, ok := lines["stripe connect webhooks"]; !ok || len(lines) != 3 {
		t.Errorf("lines = %v", lines)
	}
}

func TestFailureLogsCarrySvixIDOnlyForResend(t *testing.T) {
	var logs bytes.Buffer
	s := newStripeTestServer(t, &fakeQueue{})
	s.logger = slog.New(slog.NewJSONHandler(&logs, nil))
	req := httptest.NewRequest(http.MethodPost, "/stripe-webhook", strings.NewReader("{}"))
	req.Header.Set("svix-id", "msg_1")
	s.routes().ServeHTTP(httptest.NewRecorder(), req)
	post(s, "v1,invalid", testPayload)

	lines := strings.Split(strings.TrimSpace(logs.String()), "\n")
	if len(lines) != 2 || strings.Contains(lines[0], "svix_id") || !strings.HasPrefix(lines[1][strings.Index(lines[1], `"msg"`):], `"msg":"Error verifying Resend webhook","svix_id":"msg_2Lh9KRb0pzN4hDUM4ZD9Ht5bG9M","status":400`) {
		t.Fatalf("logs = %s", logs.String())
	}
}

// Puma joins a repeated header with ", ", and Stripe's parser then reads every v1 in it.
func TestRackHeaderJoinsRepeatedFields(t *testing.T) {
	header := http.Header{}
	header.Add("Stripe-Signature", "t=1,v1=a")
	header.Add("Stripe-Signature", "v1=b")
	if got := rackHeader(header, "Stripe-Signature"); got != "t=1,v1=a, v1=b" {
		t.Fatalf("rackHeader = %q", got)
	}
}

// sign signs a body the handler tests build; TestSignatureVerifierAcceptsTheSignatureRailsComputes
// pins the algorithm itself to a Ruby-generated signature.
func sign(t *testing.T, v *signatureVerifier, body []byte) string {
	t.Helper()
	mac := hmac.New(sha256.New, v.secret)
	mac.Write([]byte(testMessageID + "." + testTimestamp + "."))
	mac.Write(body)
	return base64.StdEncoding.EncodeToString(mac.Sum(nil))
}

func TestFailureLogsOneLinePerSecond(t *testing.T) {
	var kind failure
	start := time.Unix(1792001956, 0)
	if !kind.allowLog(start) || kind.allowLog(start.Add(900*time.Millisecond)) {
		t.Fatal("want exactly one line in the first second")
	}
	if !kind.allowLog(start.Add(time.Second)) {
		t.Fatal("want a line in the next second")
	}
}
