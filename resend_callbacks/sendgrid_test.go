package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"errors"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"
)

var rubySendgridSignedAt = time.Unix(1792001956, 0)

type fakeFlag struct {
	on    bool
	err   error
	reads int
}

func (f *fakeFlag) active(context.Context) (bool, error) {
	f.reads++
	return f.on, f.err
}

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

func newSendgridTestServer(t *testing.T, queue enqueuer, keys []string, flag featureFlag) *server {
	s := newTestServer(t, queue)
	s.sendgrid = newSendgridVerifier(keys)
	s.sendgridFlag = flag
	s.now = func() time.Time { return rubySendgridSignedAt }
	return s
}

func postSendgrid(s *server, signature, timestamp, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodPost, "/sendgrid-webhook", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	if signature != "" {
		req.Header.Set("X-Twilio-Email-Event-Webhook-Signature", signature)
	}
	if timestamp != "" {
		req.Header.Set("X-Twilio-Email-Event-Webhook-Timestamp", timestamp)
	}
	rec := httptest.NewRecorder()
	s.routes().ServeHTTP(rec, req)
	return rec
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
	ts := rubySendgridTimestamp
	body := `[{"event":"delivered","email":"buyer@example.com","sg_message_id":"abc123","category":["a",null]}]`
	for key := range signer.keys {
		queue := &fakeQueue{}
		s := newSendgridTestServer(t, queue, signer.encoded, &fakeFlag{on: true})
		rec := postSendgrid(s, signer.sign(t, key, ts, body), ts, body)
		if rec.Code != http.StatusOK || rec.Body.String() != `{"success":true}` || len(queue.jobs) != 1 {
			t.Fatalf("signed by key %d: got %d %s, pushed %d", key, rec.Code, rec.Body, len(queue.jobs))
		}
		if queue.jobs[0].job != sendgridJob {
			t.Fatalf("pushed %+v", queue.jobs[0].job)
		}
		// What a Rails 8.1 controller's params.to_unsafe_hash.to_hash is for this body.
		want := decodeJSON(t, `{"_json":[{"event":"delivered","email":"buyer@example.com","sg_message_id":"abc123","category":["a"]}],"controller":"foreign_webhooks","action":"sendgrid","foreign_webhook":{"_json":[{"event":"delivered","email":"buyer@example.com","sg_message_id":"abc123","category":["a"]}]}}`)
		if got := roundTrip(t, queue.jobs[0].arg); !reflect.DeepEqual(got, want) {
			t.Fatalf("arg = %v\nwant %v", got, want)
		}
	}
}

func TestSendgridWebhookWithTheFlagOnRejectsWhatFailsVerification(t *testing.T) {
	signer := newSendgridSigner(t, 1)
	other := newSendgridSigner(t, 1)
	ts := rubySendgridTimestamp
	body := rubySendgridBody
	cases := map[string][2]string{
		"missing signature": {"", ts},
		"missing timestamp": {signer.sign(t, 0, ts, body), ""},
		"unrelated key":     {other.sign(t, 0, ts, body), ts},
	}
	for name, headers := range cases {
		queue := &fakeQueue{}
		rec := postSendgrid(newSendgridTestServer(t, queue, signer.encoded, &fakeFlag{on: true}), headers[0], headers[1], body)
		if rec.Code != http.StatusInternalServerError || rec.Body.String() != `{"success":false}` || len(queue.jobs) != 0 {
			t.Errorf("%s: got %d %s, pushed %d", name, rec.Code, rec.Body, len(queue.jobs))
		}
	}
}

func TestSendgridWebhookWithTheFlagOffStillEnqueues(t *testing.T) {
	signer := newSendgridSigner(t, 1)
	ts := rubySendgridTimestamp
	body := rubySendgridBody
	for name, headers := range map[string][2]string{
		"valid":           {signer.sign(t, 0, ts, body), ts},
		"unsigned":        {"", ts},
		"unsigned legacy": {"", ""},
	} {
		queue := &fakeQueue{}
		flag := &fakeFlag{}
		rec := postSendgrid(newSendgridTestServer(t, queue, signer.encoded, flag), headers[0], headers[1], body)
		if rec.Code != http.StatusOK || len(queue.jobs) != 1 {
			t.Errorf("%s: got %d %s, pushed %d", name, rec.Code, rec.Body, len(queue.jobs))
		}
		// The flag is only read once a check fails.
		if wantReads := map[bool]int{true: 0, false: 1}[name == "valid"]; flag.reads != wantReads {
			t.Errorf("%s: read the flag %d times", name, flag.reads)
		}
	}
}

func TestSendgridWebhookAnswers503WhenTheFlagIsUnavailable(t *testing.T) {
	queue := &fakeQueue{}
	s := newSendgridTestServer(t, queue, newSendgridSigner(t, 1).encoded, &fakeFlag{err: errors.New("i/o timeout")})
	rec := postSendgrid(s, "", rubySendgridTimestamp, rubySendgridBody)
	if rec.Code != http.StatusServiceUnavailable || rec.Body.Len() != 0 || len(queue.jobs) != 0 {
		t.Fatalf("got %d %q, pushed %d", rec.Code, rec.Body, len(queue.jobs))
	}
}

func TestSendgridWebhookAnswers503WhenRedisFails(t *testing.T) {
	signer := newSendgridSigner(t, 1)
	s := newSendgridTestServer(t, &fakeQueue{err: errors.New("connection refused")}, signer.encoded, &fakeFlag{})
	rec := postSendgrid(s, signer.sign(t, 0, rubySendgridTimestamp, rubySendgridBody), rubySendgridTimestamp, rubySendgridBody)
	if rec.Code != http.StatusServiceUnavailable || rec.Body.Len() != 0 {
		t.Fatalf("got %d %q", rec.Code, rec.Body)
	}
}

// Rails parses the params in the action, after verification passes or is waived.
func TestSendgridWebhookRejectsAnUnparseableBodyAfterVerification(t *testing.T) {
	queue := &fakeQueue{}
	rec := postSendgrid(newSendgridTestServer(t, queue, newSendgridSigner(t, 1).encoded, &fakeFlag{}), "", "", `[{"event":`)
	if rec.Code != http.StatusBadRequest || len(queue.jobs) != 0 {
		t.Fatalf("got %d, pushed %d", rec.Code, len(queue.jobs))
	}
}
