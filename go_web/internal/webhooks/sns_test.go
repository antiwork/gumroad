package webhooks

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
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/sidekiq"
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
func messageAt(t *testing.T, url string) sidekiq.Hash {
	return snsMessage(t, rubySNSNotificationV1, map[string]any{"SigningCertURL": url})
}

func isVerificationError(err error) bool {
	return err != nil && !errors.Is(err, errRailsRaises)
}

// newTestSNSVerifier waits on another request's download as long as a test takes, so a
// busy machine can't time a join out.
func newTestSNSVerifier(host *fakeCertHost) *snsVerifier {
	v := newSNSVerifier(host.get)
	v.joinWait = time.Minute
	return v
}

func rubyCertHost() *fakeCertHost {
	return &fakeCertHost{pem: map[string]string{rubySNSCertURL: rubySNSCertPEM}}
}

// snsMessage parses body, then sets each change, or deletes the key for a nil one.
func snsMessage(t *testing.T, body string, changes map[string]any) sidekiq.Hash {
	t.Helper()
	parsed, _, err := parseJSON([]byte(body))
	if err != nil {
		t.Fatal(err)
	}
	msg := parsed.(sidekiq.Hash)
	for key, value := range changes {
		if i := pairIndex(msg, key); value == nil && i >= 0 {
			msg = append(msg[:i], msg[i+1:]...)
		} else if value != nil {
			msg, _ = setPair(msg, nil, key, value)
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
		"port other than 443":     {"SigningCertURL": "https://sns.us-east-1.amazonaws.com:81/a.pem"},
		"port 0443's prefix":      {"SigningCertURL": "https://sns.us-east-1.amazonaws.com:04430/a.pem"},
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
	lambda = append(lambda, sidekiq.Pair{Key: "SigningCertUrl"})
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

	if err := v.authenticate(context.Background(), messageAt(t, url(snsMaxDownloads))); !errors.Is(err, errNoDownloadSlot) {
		t.Fatalf("a download past the cap: %v, want errNoDownloadSlot", err)
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

func TestSNSVerifierStopsWaitingOnAnotherDownload(t *testing.T) {
	host := &fakeCertHost{anyURL: true, block: make(chan struct{})}
	v := newTestSNSVerifier(host)
	v.joinWait = 10 * time.Millisecond
	url := "https://sns.us-east-1.amazonaws.com/cert.pem"
	done := make(chan error, 1)
	go func() { done <- v.authenticate(context.Background(), messageAt(t, url)) }()
	waitFor(t, func() bool { return host.fetches.Load() == 1 })
	if err := v.authenticate(context.Background(), messageAt(t, url)); !errors.Is(err, errNoDownloadSlot) {
		t.Errorf("a join past the wait: %v, want errNoDownloadSlot", err)
	}
	close(host.block)
	if err := <-done; err != nil {
		t.Fatal(err)
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

	// A failed refresh keeps the cert, remembers no failure, and tries again after
	// snsFailureTTL; AWS publishes a rotated cert under a new URL.
	clock.advance(snsCertTTL)
	host.block = nil
	host.fail(errors.New("connection reset"))
	if err := v.authenticate(context.Background(), msg); err != nil {
		t.Fatalf("when the refresh fails: %v", err)
	}
	refreshed := func() bool {
		v.mu.Lock()
		defer v.mu.Unlock()
		return !v.certs[rubySNSCertURL].refreshing
	}
	waitFor(t, func() bool { return host.fetches.Load() == 2+snsCertAttempts && refreshed() })
	for range 3 {
		if err := v.authenticate(context.Background(), msg); err != nil {
			t.Fatalf("after a failed refresh: %v", err)
		}
	}
	if n := host.fetches.Load(); n != 2+snsCertAttempts {
		t.Fatalf("fetched %d times, want no retry inside snsFailureTTL", n)
	}
	if _, remembered := v.failures[rubySNSCertURL]; remembered {
		t.Fatal("a failed refresh was remembered as a URL failure")
	}
	clock.advance(snsFailureTTL)
	host.fail(nil)
	v.authenticate(context.Background(), msg)
	waitFor(t, func() bool { return host.fetches.Load() == 3+snsCertAttempts && refreshed() })
	v.mu.Lock()
	fresh := clock.now().Sub(v.certs[rubySNSCertURL].fetchedAt) < snsCertTTL
	v.mu.Unlock()
	if !fresh {
		t.Fatal("the retried refresh didn't renew the cert")
	}
}

// Only a cert that verified a signature is cached, so forged posts, at the real URL or
// any spelling of it, can't fill the cache or evict the real cert.
func TestSNSVerifierCachesOnlyACertThatVerified(t *testing.T) {
	host := &fakeCertHost{anyURL: true}
	v := newTestSNSVerifier(host)
	ctx := context.Background()
	forged := func(url string) sidekiq.Hash {
		return snsMessage(t, rubySNSNotificationV1, map[string]any{"Message": "forged", "SigningCertURL": url})
	}
	if err := v.authenticate(ctx, forged(rubySNSCertURL)); !isVerificationError(err) || len(v.certs) != 0 {
		t.Fatalf("a forged message: %v, %d cached", err, len(v.certs))
	}
	if err := v.authenticate(ctx, snsMessage(t, rubySNSNotificationV1, nil)); err != nil || len(v.certs) != 1 {
		t.Fatalf("the real message: %v, %d cached", err, len(v.certs))
	}

	path := strings.TrimPrefix(rubySNSCertURL, "https://sns.us-east-1.amazonaws.com")
	variants := []string{
		"https://user@sns.us-east-1.amazonaws.com" + path,
		"https://sns.us-east-1.amazonaws.com:443" + path,
		"https://sns.US-EAST-1.amazonaws.com" + path,
	}
	for i := range 2 * snsCertCacheLimit {
		variants = append(variants, rubySNSCertURL+"#"+strconv.Itoa(i))
	}
	for _, variant := range variants {
		if err := v.authenticate(ctx, forged(variant)); !isVerificationError(err) {
			t.Fatalf("%s: %v", variant, err)
		}
	}
	if _, kept := v.certs[rubySNSCertURL]; !kept || len(v.certs) != 1 {
		t.Fatalf("cache holds %d certs, the real one kept: %v", len(v.certs), kept)
	}
	fetches := host.fetches.Load()
	if err := v.authenticate(ctx, snsMessage(t, rubySNSNotificationV1, nil)); err != nil || host.fetches.Load() != fetches {
		t.Fatalf("the real message after the flood: %v, refetched %v", err, host.fetches.Load() != fetches)
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

func postSNS(h *harness, path, body string) *httptest.ResponseRecorder {
	return h.post(path, "text/plain; charset=UTF-8", body, nil)
}

func TestMediaconvertSchedulesTheNotificationFiveSecondsOut(t *testing.T) {
	h := newHarness(t, nil)
	rec := postSNS(h, "/sns-mediaconvert-webhook", rubySNSNotificationV1)
	// head :ok, typed by the request's format: HTML without an Accept header.
	if rec.Code != http.StatusOK || rec.Body.Len() != 0 || rec.Header().Get("Content-Type") != "text/html" {
		t.Fatalf("got %d %q %q", rec.Code, rec.Header().Get("Content-Type"), rec.Body)
	}
	members, err := h.jobs.ZMembers("schedule")
	if err != nil || len(members) != 1 {
		t.Fatalf("schedule = %v, %v", members, err)
	}
	score, _ := h.jobs.ZScore("schedule", members[0])
	if want := float64(h.now.UnixMicro())/1e6 + 5; score != want {
		t.Errorf("score = %f, want %f", score, want)
	}
	if !strings.HasPrefix(members[0], `{"retry":5,"queue":"default","backtrace":true,"class":"HandleSnsMediaconvertEventWorker","args":[`) || strings.Contains(members[0], "enqueued_at") {
		t.Errorf("payload = %s", members[0])
	}
	// JSON.parse(raw_post) through JSON.generate is the body Ruby generated.
	if arg := onlyArg(t, members[0]); arg != rubySNSNotificationV1 {
		t.Errorf("arg = %s", arg)
	}
	if h.jobs.Exists("queue:default") {
		t.Error("a scheduled job reached its queue")
	}
}

func TestSnsAwsConfigEnqueuesTheNotification(t *testing.T) {
	h := newHarness(t, nil)
	rec := postSNS(h, "/sns-aws-config-webhook", rubySNSConfirmation)
	payloads, args := h.pushed(t, "low")
	if rec.Code != http.StatusOK || len(args) != 1 || args[0] != rubySNSConfirmation {
		t.Fatalf("got %d, pushed %v", rec.Code, args)
	}
	if !strings.HasPrefix(payloads[0], `{"retry":5,"queue":"low","backtrace":true,"args":[`) {
		t.Errorf("payload = %s", payloads[0])
	}
}

func TestSNSWebhookRejectsAnInauthenticNotification(t *testing.T) {
	h := newHarness(t, nil)
	rec := postSNS(h, "/sns-aws-config-webhook", strings.Replace(rubySNSNotificationV1, "COMPLETE", "ERROR", 1))
	if _, args := h.pushed(t, "low"); rec.Code != http.StatusBadRequest || rec.Body.String() != failureJSON || len(args) != 0 {
		t.Fatalf("got %d %s, pushed %d", rec.Code, rec.Body, len(args))
	}
}

func TestSNSWebhookRejectsABodyThatIsNotAJSONObject(t *testing.T) {
	for name, body := range map[string]string{"not_json": "not-json", "null": "null", "array": "[]", "number": "123", "boolean": "true", "string": `"abc"`} {
		h := newHarness(t, nil)
		rec := postSNS(h, "/sns-mediaconvert-webhook", body)
		if rec.Code != http.StatusBadRequest || rec.Header().Get("Content-Type") != "application/json; charset=utf-8" || rec.Body.String() != failureJSON {
			t.Errorf("%s: got %d %q %s", name, rec.Code, rec.Header().Get("Content-Type"), rec.Body)
		}
	}
}

func TestSNSWebhookRendersTheErrorPageWhereMessageVerifierRaises(t *testing.T) {
	h := newHarness(t, nil)
	rec := postSNS(h, "/sns-mediaconvert-webhook", strings.Replace(rubySNSNotificationV1, `"SigningCertURL"`, `"SigningCertUrl_"`, 1))
	if rec.Code != http.StatusInternalServerError || !strings.Contains(rec.Body.String(), "<html") {
		t.Fatalf("got %d %.80q", rec.Code, rec.Body)
	}
}

// Fields outside the signature are the sender's, and JSON.generate raises on the string an
// unpaired low surrogate leaves.
func TestSNSWebhookFailsWhereSidekiqCannotSerializeTheNotification(t *testing.T) {
	h := newHarness(t, nil)
	rec := postSNS(h, "/sns-aws-config-webhook", strings.TrimSuffix(rubySNSNotificationV1, "}")+`,"Extra":"\udc00"}`)
	if _, args := h.pushed(t, "low"); rec.Code != http.StatusInternalServerError || len(args) != 0 {
		t.Fatalf("got %d, pushed %d", rec.Code, len(args))
	}
}

func TestSNSWebhookAnswers503WhenRedisFails(t *testing.T) {
	h := newHarness(t, nil)
	h.jobs.SetError("ERR connection lost")
	rec := postSNS(h, "/sns-mediaconvert-webhook", rubySNSNotificationV2)
	if rec.Code != http.StatusServiceUnavailable || rec.Body.Len() != 0 {
		t.Fatalf("got %d %q", rec.Code, rec.Body)
	}
}

// SNS treats a 4xx as delivered, so a full download cap answers a 503 it retries.
func TestSNSWebhookAnswers503WhenNoDownloadSlotIsFree(t *testing.T) {
	h := newHarness(t, nil)
	h.certs.anyURL, h.certs.block = true, make(chan struct{})
	body := func(i int) string {
		out, err := sidekiqMarshal(messageAt(t, "https://sns.us-east-1.amazonaws.com/cert-"+strconv.Itoa(i)+".pem"))
		if err != nil {
			t.Fatal(err)
		}
		return out
	}
	var wg sync.WaitGroup
	codes := make(chan int, snsMaxDownloads)
	for i := range snsMaxDownloads {
		b := body(i)
		wg.Go(func() { codes <- postSNS(h, "/sns-aws-config-webhook", b).Code })
	}
	waitFor(t, func() bool { return h.certs.fetches.Load() == snsMaxDownloads })
	rec := postSNS(h, "/sns-aws-config-webhook", body(snsMaxDownloads))
	close(h.certs.block)
	wg.Wait()
	close(codes)
	if rec.Code != http.StatusServiceUnavailable || rec.Body.Len() != 0 {
		t.Errorf("past the cap: got %d %q", rec.Code, rec.Body)
	}
	for code := range codes {
		if code != http.StatusOK {
			t.Errorf("a request holding a slot got %d", code)
		}
	}
}

func waitFor(t *testing.T, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !condition() {
		if time.Now().After(deadline) {
			t.Fatal("timed out")
		}
		time.Sleep(time.Millisecond)
	}
}

func TestCertFetchTargetReadsThePortAsANumber(t *testing.T) {
	for _, raw := range []string{"https://sns.us-east-1.amazonaws.com:443/a.pem", "https://sns.us-east-1.amazonaws.com:0443/a.pem"} {
		if got, err := certFetchTarget(raw); err != nil || got != "https://sns.us-east-1.amazonaws.com/a.pem" {
			t.Errorf("%s: %q, %v", raw, got, err)
		}
	}
	if _, err := certFetchTarget("https://sns.us-east-1.amazonaws.com:8443/a.pem"); err == nil {
		t.Error("port 8443 accepted")
	}
}
