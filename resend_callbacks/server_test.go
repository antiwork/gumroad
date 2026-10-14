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
	"strings"
	"testing"
	"time"
)

type fakeQueue struct {
	events []map[string]any
	err    error
}

func (q *fakeQueue) enqueue(_ context.Context, event map[string]any) error {
	if q.err != nil {
		return q.err
	}
	q.events = append(q.events, event)
	return nil
}

func newTestServer(t *testing.T, queue enqueuer) *server {
	t.Helper()
	verifier, err := newSignatureVerifier(testWebhookSecret)
	if err != nil {
		t.Fatal(err)
	}
	return &server{
		verifier: verifier,
		filter:   newEventFilter(testHeaderKey),
		queue:    queue,
		logger:   slog.New(slog.NewTextHandler(io.Discard, nil)),
		now:      func() time.Time { return testSignedAt },
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
	rec := post(s, "v1,"+sign(t, s.verifier, body), string(body))
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
	rec := post(s, "v1,"+sign(t, s.verifier, body), string(body))
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
	rec := post(s, "v1,"+sign(t, s.verifier, body), string(body))
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

func TestOtherPathsAreNotServed(t *testing.T) {
	rec := httptest.NewRecorder()
	newTestServer(t, &fakeQueue{}).routes().ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/stripe-webhook", bytes.NewReader(nil)))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("got %d", rec.Code)
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
