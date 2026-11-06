package webhooks

import (
	"context"
	"crypto"
	"crypto/rsa"
	_ "crypto/sha1" // SignatureVersion 1
	"crypto/x509"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"regexp"
	"strconv"
	"sync"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/sidekiq"
	"github.com/antiwork/gumroad/go_web/internal/web"
)

const (
	// HandleSnsMediaconvertEventWorker.perform_in(5.seconds, notification).
	mediaconvertDelay = 5 * time.Second

	// Aws::SNS::MessageVerifier#https_get tries three times.
	snsCertAttempts = 3
	// Net::HTTP waits 60s per attempt; this keeps three inside the request timeout.
	snsCertTimeout  = 5 * time.Second
	snsCertMaxBytes = 64 << 10
	// Rails builds a verifier per request, so it never reuses a certificate. AWS
	// publishes a rotated signing cert under a new URL, so caching by URL is safe.
	snsCertTTL        = time.Hour
	snsCertCacheLimit = 32
	// A URL whose fetch just failed answers from memory, so a flood can't refetch it.
	snsFailureTTL   = 30 * time.Second
	snsFailureLimit = 256
	// The route is unauthenticated, so past this many distinct downloads the request gets
	// a 503 and SNS retries it.
	snsMaxDownloads = 4
)

// MessageVerifier::SIGNABLE_KEYS. Every one present goes into the canonical string,
// whatever the message Type, unlike AWS's documented per-Type lists.
var snsSignableKeys = []string{"Message", "MessageId", "Subject", "SubscribeURL", "Timestamp", "Token", "TopicArn", "Type"}

var (
	snsCertHost = regexp.MustCompile(`^sns\.[a-zA-Z0-9\-]{3,}\.amazonaws\.com(\.cn)?$`)
	// verify_pem_format!'s pattern; Ruby's \s includes \v, and [\s]*\Z is [\s]*\z.
	snsPEMFormat = regexp.MustCompile(`\A[` + rails.RubySpace + `]*-----BEGIN [A-Z]+-----\n[A-Za-z0-9+/\n]+={0,2}\n-----END [A-Z]+-----[` + rails.RubySpace + `]*\z`)

	errNoDownloadSlot = errors.New("too many signing cert downloads in flight")
)

// sns is #mediaconvert and #sns_aws_config: validate_sns_webhook, then the action, which
// passes JSON.parse(request.raw_post) to its job.
func (h *handlers) sns(v *snsVerifier, action string, job sidekiq.Options, delay time.Duration, incoming string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		in, ok := h.begin(w, r, action, maxBodyBytes)
		if !ok {
			return
		}
		// SNS posts text/plain, and anything that isn't a JSON object is a rejected sender.
		parsed, loneLow, err := parseJSON(in.body)
		notification, isObject := parsed.(sidekiq.Hash)
		if err != nil || !isObject {
			rails.RenderJSON(w, in.req, http.StatusBadRequest, failureJSON)
			return
		}
		if err := v.authenticate(r.Context(), notification); err != nil {
			if errors.Is(err, errNoDownloadSlot) {
				// SNS counts a 4xx as delivered, so a 503 is what gets it redelivered.
				web.Logger(r).Warn("SNS signing cert downloads are all busy")
				rails.Head(w, in.req, http.StatusServiceUnavailable)
			} else if errors.Is(err, errRailsRaises) {
				h.raise(in, "Error verifying SNS message", err)
			} else {
				rails.RenderJSON(w, in.req, http.StatusBadRequest, failureJSON)
			}
			return
		}
		web.Logger(r).Info(incoming, "notification", string(in.body))
		if h.push(in, job, delay, notification, loneLow) {
			rails.Head(w, in.req, http.StatusOK)
		}
	}
}

// snsVerifier ports Aws::SNS::MessageVerifier#authenticate! (aws-sdk-sns 1.82.0). A
// returned error is a VerificationError (authentic? is false, a 400) unless it wraps
// errRailsRaises.
type snsVerifier struct {
	get       certGetter
	now       func() time.Time
	downloads chan struct{}
	joinWait  time.Duration

	mu sync.Mutex
	// All keyed by the raw SigningCertURL, so a cached one skips URI parsing.
	certs    map[string]*snsCert
	fetches  map[string]*snsFetch
	failures map[string]snsFailure
}

type snsCert struct {
	key        *rsa.PublicKey
	url        string
	fetchedAt  time.Time
	refreshing bool
	// A failed refresh keeps the cert and tries again after snsFailureTTL.
	retryAt time.Time
}

type snsFetch struct {
	done chan struct{}
	key  *rsa.PublicKey
	url  string
	err  error
}

type snsFailure struct {
	err error
	at  time.Time
}

func newSNSVerifier(get certGetter) *snsVerifier {
	return &snsVerifier{
		get:       get,
		now:       time.Now,
		downloads: make(chan struct{}, snsMaxDownloads),
		joinWait:  snsJoinWait,
		certs:     map[string]*snsCert{},
		fetches:   map[string]*snsFetch{},
		failures:  map[string]snsFailure{},
	}
}

func newCertGetter() certGetter {
	client := &http.Client{
		// Net::HTTP doesn't follow redirects, so a 3xx is just a non-200.
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	return func(ctx context.Context, url string) ([]byte, error) { return httpsGet(ctx, client, url) }
}

func httpsGet(ctx context.Context, client *http.Client, url string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, snsCertMaxBytes+1))
	switch {
	case err != nil:
		return nil, err
	case resp.StatusCode != http.StatusOK:
		return nil, fmt.Errorf("signing cert fetch answered %d", resp.StatusCode)
	case len(body) > snsCertMaxBytes:
		return nil, errors.New("signing cert response too large")
	}
	return body, nil
}

func (v *snsVerifier) authenticate(ctx context.Context, msg sidekiq.Hash) error {
	certURL, _ := get(msg, "SigningCertURL")
	// A message relayed by Lambda spells the key SigningCertUrl, and that one wins.
	if lambdaURL, fromLambda := get(msg, "SigningCertUrl"); fromLambda {
		certURL = lambdaURL
	}
	version, _ := get(msg, "SignatureVersion")
	var hash crypto.Hash
	switch version {
	case "1":
		hash = crypto.SHA1
	case "2":
		hash = crypto.SHA256
	default:
		return errors.New("Invalid SignatureVersion")
	}

	// Ruby evaluates public_key, then signature, then canonical_string.
	rawURL, ok := certURL.(string)
	if !ok {
		return fmt.Errorf("%w: SigningCertURL is not a string", errRailsRaises)
	}
	key, fetchedURL, err := v.publicKey(ctx, rawURL)
	if err != nil {
		return err
	}
	signature, _ := get(msg, "Signature")
	encoded, ok := signature.(string)
	if !ok {
		return fmt.Errorf("%w: Signature is not a string", errRailsRaises)
	}
	canonical, matchable, err := snsCanonicalString(msg)
	if err != nil {
		return err
	}
	digest := hash.New()
	digest.Write(canonical)
	if !matchable || rsa.VerifyPKCS1v15(key, hash, digest.Sum(nil), rubyDecode64(encoded)) != nil {
		return errors.New("the authenticity of the message cannot be verified")
	}
	if fetchedURL != "" {
		v.admit(rawURL, fetchedURL, key)
	}
	return nil
}

// snsCanonicalString builds canonical_string. A signable value that's neither nil, a
// string nor a container has no empty?, so Ruby raises; a non-empty container is
// interpolated with #inspect, which no signature covers.
func snsCanonicalString(msg sidekiq.Hash) (canonical []byte, matchable bool, err error) {
	matchable = true
	for _, key := range snsSignableKeys {
		value, _ := get(msg, key)
		switch value := value.(type) {
		case nil:
		case string:
			if value != "" {
				canonical = fmt.Appendf(canonical, "%s\n%s\n", key, value)
			}
		case []any:
			matchable = matchable && len(value) == 0
		case sidekiq.Hash:
			matchable = matchable && len(value) == 0
		default:
			return nil, false, fmt.Errorf("%w: %s has no empty?", errRailsRaises, key)
		}
	}
	return canonical, matchable, nil
}

// publicKey serves a cached key, joins a fetch in flight, or replays a recent failure.
// Otherwise it runs URI.parse and verify_uri! and downloads the certificate. fetchedURL
// is set for a key not yet cached, which authenticate admits once a signature verifies.
func (v *snsVerifier) publicKey(ctx context.Context, rawURL string) (key *rsa.PublicKey, fetchedURL string, err error) {
	key, fetch, cached, err := v.lookup(rawURL)
	if cached {
		return key, "", err
	}
	if fetch == nil {
		url, err := certFetchTarget(rawURL)
		if err != nil {
			return nil, "", err
		}
		v.mu.Lock()
		key, fetch, cached, err = v.lookupLocked(rawURL)
		if cached {
			v.mu.Unlock()
			return key, "", err
		}
		if fetch == nil {
			if !v.acquire() {
				v.mu.Unlock()
				return nil, "", errNoDownloadSlot
			}
			fetch = &snsFetch{done: make(chan struct{}), url: url}
			v.fetches[rawURL] = fetch
			v.mu.Unlock()
			// Detached so a disconnecting sender doesn't fail the fetch for the others waiting.
			fetch.key, fetch.err = v.download(context.WithoutCancel(ctx), url)
			<-v.downloads
			v.settle(rawURL, fetch.err)
			close(fetch.done)
			if fetch.err != nil {
				return nil, "", fetch.err
			}
			return fetch.key, fetch.url, nil
		} else {
			v.mu.Unlock()
		}
	}
	join := time.NewTimer(v.joinWait)
	defer join.Stop()
	select {
	case <-fetch.done:
		if fetch.err != nil {
			return nil, "", fetch.err
		}
		return fetch.key, fetch.url, nil
	case <-join.C:
		return nil, "", fmt.Errorf("waiting on another signing cert download: %w", errNoDownloadSlot)
	case <-ctx.Done():
		return nil, "", ctx.Err()
	}
}

// snsJoinWait bounds how long a request waits on another's download: longer would only hold
// its share of the webhooks' in-flight budget, and SNS redelivers on the 503.
const snsJoinWait = 2 * time.Second

func (v *snsVerifier) lookup(rawURL string) (*rsa.PublicKey, *snsFetch, bool, error) {
	v.mu.Lock()
	defer v.mu.Unlock()
	return v.lookupLocked(rawURL)
}

// lookupLocked starts one background refresh of an expired cert, which keeps being
// served until the refresh lands.
func (v *snsVerifier) lookupLocked(rawURL string) (*rsa.PublicKey, *snsFetch, bool, error) {
	now := v.now()
	if cert, ok := v.certs[rawURL]; ok {
		if now.Sub(cert.fetchedAt) >= snsCertTTL && !cert.refreshing && !now.Before(cert.retryAt) && v.acquire() {
			cert.refreshing = true
			go v.refresh(rawURL, cert)
		}
		return cert.key, nil, true, nil
	}
	if failure, ok := v.failures[rawURL]; ok && now.Sub(failure.at) < snsFailureTTL {
		return nil, nil, true, failure.err
	}
	return nil, v.fetches[rawURL], false, nil
}

// refresh keeps a cert through a failed download. A different key at the same URL isn't
// admitted unverified: the entry goes, and the next message verifies afresh.
func (v *snsVerifier) refresh(rawURL string, stale *snsCert) {
	key, err := v.download(context.Background(), stale.url)
	<-v.downloads
	v.mu.Lock()
	defer v.mu.Unlock()
	stale.refreshing = false
	switch {
	case v.certs[rawURL] != stale:
	case err != nil:
		stale.retryAt = v.now().Add(snsFailureTTL)
	case key.Equal(stale.key):
		stale.fetchedAt = v.now()
	default:
		delete(v.certs, rawURL)
	}
}

// settle ends a download, remembering a failure for snsFailureTTL.
func (v *snsVerifier) settle(rawURL string, err error) {
	v.mu.Lock()
	defer v.mu.Unlock()
	delete(v.fetches, rawURL)
	if err == nil {
		return
	}
	now := v.now()
	if len(v.failures) >= snsFailureLimit {
		for failed, failure := range v.failures {
			if now.Sub(failure.at) >= snsFailureTTL {
				delete(v.failures, failed)
			}
		}
	}
	if len(v.failures) >= snsFailureLimit {
		delete(v.failures, oldest(v.failures, func(f snsFailure) time.Time { return f.at }))
	}
	v.failures[rawURL] = snsFailure{err: err, at: now}
}

// admit caches a key that has verified a signature, evicting the oldest.
func (v *snsVerifier) admit(rawURL, url string, key *rsa.PublicKey) {
	v.mu.Lock()
	defer v.mu.Unlock()
	if _, ok := v.certs[rawURL]; ok {
		return
	}
	delete(v.failures, rawURL)
	if len(v.certs) >= snsCertCacheLimit {
		delete(v.certs, oldest(v.certs, func(c *snsCert) time.Time { return c.fetchedAt }))
	}
	v.certs[rawURL] = &snsCert{key: key, url: url, fetchedAt: v.now()}
}

func oldest[T any](entries map[string]T, at func(T) time.Time) string {
	var key string
	var earliest time.Time
	for k, entry := range entries {
		if t := at(entry); key == "" || t.Before(earliest) {
			key, earliest = k, t
		}
	}
	return key
}

func (v *snsVerifier) acquire() bool {
	select {
	case v.downloads <- struct{}{}:
		return true
	default:
		return false
	}
}

// certFetchTarget runs URI.parse and verify_uri! on a SigningCertURL, returning what
// Net::HTTP would request.
func certFetchTarget(rawURL string) (string, error) {
	u, err := rails.ParseURI(rawURL)
	if err != nil {
		return "", fmt.Errorf("%w: %w", errRailsRaises, err)
	}
	if u.Scheme != "https" {
		return "", errors.New("the SigningCertURL must be https")
	}
	if !u.HasHost || !snsCertHost.MatchString(u.Host) {
		return "", errors.New("signing cert is not hosted by AWS")
	}
	if rails.FileExtname(u.Path) != ".pem" {
		return "", errors.New("the SigningCertURL must link to a .pem file")
	}
	// AWS serves signing certs on 443 only. Rails would try another port and fail, after a
	// connect that can hang; refusing it at once answers the same 400.
	if port, err := strconv.Atoi(u.Port); u.Port != "" && (err != nil || port != 443) {
		return "", errors.New("the SigningCertURL must use port 443")
	}
	return certFetchURL(u), nil
}

// download is download_pem plus public_key's parsing. Only a fetch or format failure
// is a VerificationError; a bad certificate or a non-RSA key raises.
func (v *snsVerifier) download(ctx context.Context, url string) (*rsa.PublicKey, error) {
	var body []byte
	var err error
	for range snsCertAttempts {
		attemptCtx, cancel := context.WithTimeout(ctx, snsCertTimeout)
		body, err = v.get(attemptCtx, url)
		cancel()
		if err == nil {
			break
		}
	}
	if err != nil {
		return nil, err
	}
	if !snsPEMFormat.Match(body) {
		return nil, errors.New("The certificate does not match expected X509 PEM format.")
	}
	block, _ := pem.Decode(body)
	if block == nil || block.Type != "CERTIFICATE" {
		return nil, fmt.Errorf("%w: signing cert is not a PEM certificate", errRailsRaises)
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errRailsRaises, err)
	}
	key, ok := cert.PublicKey.(*rsa.PublicKey)
	if !ok {
		return nil, fmt.Errorf("%w: signing cert key is not RSA", errRailsRaises)
	}
	return key, nil
}

// certFetchURL is what Net::HTTP requests: uri.host and uri.port, then request_uri.
// Userinfo and the fragment are dropped.
func certFetchURL(u rails.URI) string {
	port := 443
	if u.Port != "" {
		// An unusable port fails the request, as it fails Net::HTTP's connect.
		var err error
		if port, err = strconv.Atoi(u.Port); err != nil {
			port = -1
		}
	}
	host := u.Host
	if port != 443 {
		host = net.JoinHostPort(u.Host, strconv.Itoa(port))
	}
	url := "https://" + host + u.Path
	if u.Query != nil {
		url += "?" + *u.Query
	}
	return url
}
