package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"errors"
	"math/big"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type fakeCertHost struct {
	pem     map[string]string
	anyURL  bool          // serve rubySNSCertPEM at every URL
	block   chan struct{} // when set, fetches wait for it to close
	fetches atomic.Int64

	mu  sync.Mutex
	err error
}

func (h *fakeCertHost) get(_ context.Context, url string) ([]byte, error) {
	h.fetches.Add(1)
	if h.block != nil {
		<-h.block
	}
	h.mu.Lock()
	err := h.err
	h.mu.Unlock()
	if err != nil {
		return nil, err
	}
	if h.anyURL {
		return []byte(rubySNSCertPEM), nil
	}
	body, ok := h.pem[url]
	if !ok {
		return nil, errors.New("404")
	}
	return []byte(body), nil
}

func (h *fakeCertHost) fail(err error) {
	h.mu.Lock()
	h.err = err
	h.mu.Unlock()
}

// testClock is safe to read from a background refresh.
type testClock struct{ nanos atomic.Int64 }

func newTestClock() *testClock {
	c := &testClock{}
	c.nanos.Store(time.Unix(1792001956, 0).UnixNano())
	return c
}

func (c *testClock) now() time.Time          { return time.Unix(0, c.nanos.Load()) }
func (c *testClock) advance(d time.Duration) { c.nanos.Add(int64(d)) }

// The canonical string leaves SigningCertURL out, so the Ruby-signed message stays
// authentic at any URL serving its certificate.
func messageAt(t *testing.T, url string) map[string]any {
	return snsMessage(t, rubySNSNotificationV1, map[string]any{"SigningCertURL": url})
}

func isVerificationError(err error) bool {
	return err != nil && !errors.Is(err, errRailsRaises)
}

func newTestSNSVerifier(host *fakeCertHost) *snsVerifier {
	return newSNSVerifier(host.get)
}

func rubyCertHost() *fakeCertHost {
	return &fakeCertHost{pem: map[string]string{rubySNSCertURL: rubySNSCertPEM}}
}

func snsMessage(t *testing.T, body string, changes map[string]any) map[string]any {
	t.Helper()
	msg := decodeJSON(t, body).(map[string]any)
	for key, value := range changes {
		if value == nil {
			delete(msg, key)
		} else {
			msg[key] = value
		}
	}
	return msg
}

func TestSNSVerifierAcceptsWhatMessageVerifierAccepts(t *testing.T) {
	v := newTestSNSVerifier(rubyCertHost())
	for name, body := range map[string]string{
		"v1 Notification":          rubySNSNotificationV1,
		"v2 Notification":          rubySNSNotificationV2,
		"SubscriptionConfirmation": rubySNSConfirmation,
	} {
		if err := v.authenticate(context.Background(), snsMessage(t, body, nil)); err != nil {
			t.Errorf("%s: authenticate() = %v", name, err)
		}
	}
	// nil keys and empty containers stay out of the canonical string.
	if err := v.authenticate(context.Background(), snsMessage(t, rubySNSNotificationV2, map[string]any{"Subject": []any{}})); err != nil {
		t.Errorf("an empty Subject list: %v", err)
	}
	lambda := snsMessage(t, rubySNSNotificationV1, map[string]any{"SigningCertURL": nil, "SigningCertUrl": rubySNSCertURL})
	if err := v.authenticate(context.Background(), lambda); err != nil {
		t.Errorf("a message relayed by Lambda: %v", err)
	}
}

func TestSNSVerifierRejectsWhatMessageVerifierRejects(t *testing.T) {
	v := newTestSNSVerifier(rubyCertHost())
	cases := map[string]map[string]any{
		"tampered Message":        {"Message": "x"},
		"Token on a Notification": {"Token": "x"},
		"non-empty Subject list":  {"Subject": []any{"MediaConvert Job State Change"}},
		"SignatureVersion 3":      {"SignatureVersion": "3"},
		"numeric version":         {"SignatureVersion": json.Number("1")},
		"no SignatureVersion":     {"SignatureVersion": nil},
		"http cert URL":           {"SigningCertURL": "http://sns.us-east-1.amazonaws.com/a.pem"},
		"uppercase host":          {"SigningCertURL": "https://SNS.us-east-1.amazonaws.com/a.pem"},
		"other host":              {"SigningCertURL": "https://sns.us-east-1.amazonaws.com.example.com/a.pem"},
		"not a .pem":              {"SigningCertURL": "https://sns.us-east-1.amazonaws.com/a.crt"},
		"relative cert URL":       {"SigningCertURL": "//sns.us-east-1.amazonaws.com/a.pem"},
		"opaque cert URL":         {"SigningCertURL": "https:a.pem"},
		"empty cert URL":          {"SigningCertURL": ""},
		"cert not found":          {"SigningCertURL": "https://sns.us-east-1.amazonaws.com/missing.pem"},
		"Lambda's key wins":       {"SigningCertUrl": "https://sns.us-east-1.amazonaws.com/missing.pem"},
	}
	for name, changes := range cases {
		err := v.authenticate(context.Background(), snsMessage(t, rubySNSNotificationV1, changes))
		if err == nil || errors.Is(err, errRailsRaises) {
			t.Errorf("%s: authenticate() = %v, want a VerificationError", name, err)
		}
	}
}

func TestSNSVerifierRaisesWhereMessageVerifierRaises(t *testing.T) {
	ecKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "ec"}, NotAfter: time.Now().Add(time.Hour)}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &ecKey.PublicKey, ecKey)
	if err != nil {
		t.Fatal(err)
	}
	host := rubyCertHost()
	host.pem["https://sns.us-east-1.amazonaws.com/ec.pem"] = string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}))
	host.pem["https://sns.us-east-1.amazonaws.com/garbage.pem"] = "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n"
	v := newTestSNSVerifier(host)
	cases := map[string]map[string]any{
		"no cert URL":         {"SigningCertURL": nil},
		"numeric cert URL":    {"SigningCertURL": json.Number("5")},
		"cert URL with space": {"SigningCertURL": "https://sns.us-east-1.amazonaws.com/a b.pem"},
		"bad query escape":    {"SigningCertURL": rubySNSCertURL + "?a=%zz"},
		"EC certificate":      {"SigningCertURL": "https://sns.us-east-1.amazonaws.com/ec.pem"},
		"unparseable cert":    {"SigningCertURL": "https://sns.us-east-1.amazonaws.com/garbage.pem"},
		"no Signature":        {"Signature": nil},
		"numeric Subject":     {"Subject": json.Number("1")},
		"boolean Token":       {"Token": false},
	}
	for name, changes := range cases {
		err := v.authenticate(context.Background(), snsMessage(t, rubySNSNotificationV1, changes))
		if !errors.Is(err, errRailsRaises) {
			t.Errorf("%s: authenticate() = %v, want it to raise", name, err)
		}
	}
	// convert_lambda_msg copies SigningCertUrl over even when it is null.
	lambda := snsMessage(t, rubySNSNotificationV1, nil)
	lambda["SigningCertUrl"] = nil
	if err := v.authenticate(context.Background(), lambda); !errors.Is(err, errRailsRaises) {
		t.Errorf("a null SigningCertUrl: authenticate() = %v, want it to raise", err)
	}
	// public_key runs before canonical_string, so a bad host wins over a bad Subject.
	msg := snsMessage(t, rubySNSNotificationV1, map[string]any{"Subject": json.Number("1"), "SigningCertURL": "https://example.com/a.pem"})
	if err := v.authenticate(context.Background(), msg); err == nil || errors.Is(err, errRailsRaises) {
		t.Errorf("authenticate() = %v, want the host check's VerificationError", err)
	}
}

func TestSNSVerifierFetchesACertificateOnce(t *testing.T) {
	host := rubyCertHost()
	v := newTestSNSVerifier(host)
	for range 3 {
		if err := v.authenticate(context.Background(), snsMessage(t, rubySNSNotificationV1, nil)); err != nil {
			t.Fatal(err)
		}
	}
	if n := host.fetches.Load(); n != 1 {
		t.Fatalf("fetched %d times", n)
	}

	malformed := &fakeCertHost{pem: map[string]string{rubySNSCertURL: "not a certificate"}}
	if err := newTestSNSVerifier(malformed).authenticate(context.Background(), snsMessage(t, rubySNSNotificationV1, nil)); !isVerificationError(err) {
		t.Fatalf("a body failing verify_pem_format!: %v", err)
	}
}

func TestSNSVerifierRemembersAFailedFetchBriefly(t *testing.T) {
	host := rubyCertHost()
	host.fail(errors.New("connection reset"))
	clock := newTestClock()
	v := newTestSNSVerifier(host)
	v.now = clock.now
	msg := snsMessage(t, rubySNSNotificationV1, nil)

	for range 2 {
		if err := v.authenticate(context.Background(), msg); !isVerificationError(err) {
			t.Fatalf("authenticate() = %v", err)
		}
	}
	if n := host.fetches.Load(); n != snsCertAttempts {
		t.Fatalf("fetched %d times, want one download of %d attempts", n, snsCertAttempts)
	}

	clock.advance(snsFailureTTL)
	host.fail(nil)
	if err := v.authenticate(context.Background(), msg); err != nil {
		t.Fatalf("after the failure expired: %v", err)
	}
}

func TestSNSVerifierCapsConcurrentDownloads(t *testing.T) {
	host := &fakeCertHost{anyURL: true, block: make(chan struct{})}
	v := newTestSNSVerifier(host)
	url := func(i int) string { return "https://sns.us-east-1.amazonaws.com/cert-" + strconv.Itoa(i) + ".pem" }

	var wg sync.WaitGroup
	errs := make(chan error, snsMaxDownloads+1)
	for i := range snsMaxDownloads {
		wg.Go(func() { errs <- v.authenticate(context.Background(), messageAt(t, url(i))) })
	}
	waitFor(t, func() bool { return host.fetches.Load() == snsMaxDownloads })
	// Joining a download in flight needs no slot of its own.
	wg.Go(func() { errs <- v.authenticate(context.Background(), messageAt(t, url(0))) })

	if err := v.authenticate(context.Background(), messageAt(t, url(snsMaxDownloads))); !errors.Is(err, errNoDownloadSlot) || !isVerificationError(err) {
		t.Fatalf("a download past the cap: %v, want the same 400 as a failed fetch", err)
	}
	close(host.block)
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}
	if n := host.fetches.Load(); n != snsMaxDownloads {
		t.Fatalf("fetched %d times", n)
	}
}

func TestSNSVerifierServesAnExpiredCertWhileOneRefreshRuns(t *testing.T) {
	host := rubyCertHost()
	clock := newTestClock()
	v := newTestSNSVerifier(host)
	v.now = clock.now
	msg := snsMessage(t, rubySNSNotificationV1, nil)
	if err := v.authenticate(context.Background(), msg); err != nil {
		t.Fatal(err)
	}

	clock.advance(snsCertTTL)
	host.block = make(chan struct{})
	for range 3 {
		if err := v.authenticate(context.Background(), msg); err != nil {
			t.Fatalf("during the refresh: %v", err)
		}
	}
	waitFor(t, func() bool { return host.fetches.Load() == 2 })
	close(host.block)
	waitFor(t, func() bool {
		v.mu.Lock()
		defer v.mu.Unlock()
		cert := v.certs[rubySNSCertURL]
		return cert != nil && !cert.refreshing
	})
	if n := host.fetches.Load(); n != 2 {
		t.Fatalf("fetched %d times, want one refresh", n)
	}

	// A refresh that fails drops the cert, as Rails' next fetch would fail.
	clock.advance(snsCertTTL)
	host.block = nil
	host.fail(errors.New("404"))
	v.authenticate(context.Background(), msg)
	waitFor(t, func() bool {
		v.mu.Lock()
		defer v.mu.Unlock()
		return v.certs[rubySNSCertURL] == nil
	})
	if err := v.authenticate(context.Background(), msg); !isVerificationError(err) {
		t.Fatalf("after a failed refresh: %v", err)
	}
}

func TestSNSVerifierEvictsTheOldestCert(t *testing.T) {
	host := &fakeCertHost{anyURL: true}
	clock := newTestClock()
	v := newTestSNSVerifier(host)
	v.now = clock.now
	url := func(i int) string { return "https://sns.us-east-1.amazonaws.com/cert-" + strconv.Itoa(i) + ".pem" }
	for i := range snsCertCacheLimit + 1 {
		clock.advance(time.Second)
		if err := v.authenticate(context.Background(), messageAt(t, url(i))); err != nil {
			t.Fatal(err)
		}
	}
	if _, kept := v.certs[url(0)]; kept || len(v.certs) != snsCertCacheLimit {
		t.Fatalf("kept the oldest: %v, %d cached", kept, len(v.certs))
	}
	if _, kept := v.certs[url(1)]; !kept {
		t.Fatal("evicted a newer cert")
	}
}

func TestHTTPSGetFollowsNetHTTP(t *testing.T) {
	ts := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/cert.pem":
			w.Write([]byte(rubySNSCertPEM))
		case "/moved.pem":
			http.Redirect(w, r, "/cert.pem", http.StatusFound)
		default:
			http.NotFound(w, r)
		}
	}))
	defer ts.Close()
	client := ts.Client()
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	if body, err := httpsGet(context.Background(), client, ts.URL+"/cert.pem"); err != nil || string(body) != rubySNSCertPEM {
		t.Fatalf("httpsGet() = %q, %v", body, err)
	}
	for _, path := range []string{"/moved.pem", "/missing.pem"} {
		if _, err := httpsGet(context.Background(), client, ts.URL+path); err == nil {
			t.Errorf("%s: a non-200 was accepted", path)
		}
	}
}

func newSNSTestServer(t *testing.T, queue enqueuer) *server {
	s := newTestServer(t, queue)
	s.sns = newTestSNSVerifier(rubyCertHost())
	return s
}

func postSNS(s *server, path, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodPost, path, strings.NewReader(body))
	req.Header.Set("Content-Type", "text/plain; charset=UTF-8")
	rec := httptest.NewRecorder()
	s.routes().ServeHTTP(rec, req)
	return rec
}

func TestSNSWebhooksScheduleAndEnqueueTheNotification(t *testing.T) {
	cases := map[string]struct {
		job   jobSpec
		delay time.Duration
	}{
		"/sns-mediaconvert-webhook": {mediaconvertJob, 5 * time.Second},
		"/sns-aws-config-webhook":   {awsConfigJob, 0},
	}
	for path, tc := range cases {
		queue := &fakeQueue{}
		rec := postSNS(newSNSTestServer(t, queue), path, rubySNSNotificationV1)
		if rec.Code != http.StatusOK || rec.Body.Len() != 0 {
			t.Fatalf("%s: got %d %q, want head :ok", path, rec.Code, rec.Body)
		}
		if len(queue.jobs) != 1 || queue.jobs[0].job != tc.job || queue.jobs[0].delay != tc.delay {
			t.Fatalf("%s: pushed %+v", path, queue.jobs)
		}
		if got, want := roundTrip(t, queue.jobs[0].arg), decodeJSON(t, rubySNSNotificationV1); !reflect.DeepEqual(got, want) {
			t.Fatalf("%s: arg = %v", path, got)
		}
	}
}

func TestSNSWebhookRejectsAnInauthenticNotification(t *testing.T) {
	queue := &fakeQueue{}
	body := strings.Replace(rubySNSNotificationV1, "COMPLETE", "ERROR", 1)
	rec := postSNS(newSNSTestServer(t, queue), "/sns-aws-config-webhook", body)
	if rec.Code != http.StatusBadRequest || rec.Body.String() != `{"success":false}` || len(queue.jobs) != 0 {
		t.Fatalf("got %d %s, pushed %d", rec.Code, rec.Body, len(queue.jobs))
	}
}

func TestSNSWebhookRejectsABodyThatIsNotAJSONObject(t *testing.T) {
	for name, body := range map[string]string{"not_json": "not-json", "null": "null", "array": "[]", "number": "123", "boolean": "true", "string": `"abc"`} {
		queue := &fakeQueue{}
		rec := postSNS(newSNSTestServer(t, queue), "/sns-mediaconvert-webhook", body)
		if rec.Code != http.StatusBadRequest || rec.Header().Get("Content-Type") != "application/json; charset=utf-8" || rec.Body.String() != `{"success":false}` || len(queue.jobs) != 0 {
			t.Errorf("%s: got %d %q %s", name, rec.Code, rec.Header().Get("Content-Type"), rec.Body)
		}
	}
}

// Fields outside the signature are the sender's, and JSON.generate raises on one that isn't UTF-8.
func TestSNSWebhookFailsWhereSidekiqCannotSerializeTheNotification(t *testing.T) {
	queue := &fakeQueue{}
	body := strings.TrimSuffix(rubySNSNotificationV1, "}") + `,"Extra":"\udc00"}`
	rec := postSNS(newSNSTestServer(t, queue), "/sns-aws-config-webhook", body)
	if rec.Code != http.StatusInternalServerError || len(queue.jobs) != 0 {
		t.Fatalf("got %d, pushed %d", rec.Code, len(queue.jobs))
	}
}

func TestSNSWebhookAnswers503WhenRedisFails(t *testing.T) {
	rec := postSNS(newSNSTestServer(t, &fakeQueue{err: errors.New("connection refused")}), "/sns-mediaconvert-webhook", rubySNSNotificationV2)
	if rec.Code != http.StatusServiceUnavailable || rec.Body.Len() != 0 {
		t.Fatalf("got %d %q", rec.Code, rec.Body)
	}
}
