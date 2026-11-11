package webhooks

import (
	"encoding/base64"
	"io"
	"maps"
	"net/http"
	"net/http/httptest"
	"os"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"
)

const (
	paypalClientID     = "paypal-client"
	paypalClientSecret = "paypal-secret"
	paypalTokenPath    = "/v1/oauth2/token"
	paypalVerifyPath   = "/v1/notifications/verify-webhook-signature"
	paypalTokenJSON    = `{"scope":"https://uri.paypal.com/services/applications/webhooks","access_token":"A21AAtest","token_type":"Bearer","app_id":"APP-80W284485P519543T","expires_in":32400,"nonce":"2026-11-10T08:12:10Zabc"}`
	// The Redis::Namespace key PaypalPartnerRestCredentials reads and writes.
	railsPaypalTokenKey = "paypal_partner_rest_auth_token:token_header"
)

type paypalAnswer struct {
	status      int
	contentType string
	body        string
}

type paypalRequest struct {
	path, contentType, accept, acceptLanguage, authorization, body string
}

// fakePaypal serves the token and verify endpoints and records each request. A path set to
// a nil answer hangs up without answering; a held fake answers nothing until released.
type fakePaypal struct {
	server *httptest.Server

	mu       sync.Mutex
	answers  map[string]*paypalAnswer
	requests []paypalRequest
	held     chan struct{}
}

func newFakePaypal(t *testing.T) *fakePaypal {
	f := &fakePaypal{answers: map[string]*paypalAnswer{
		paypalTokenPath:  {http.StatusOK, "application/json", paypalTokenJSON},
		paypalVerifyPath: {http.StatusOK, "application/json", `{"verification_status":"SUCCESS"}`},
	}}
	f.server = httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.server.Close)
	return f
}

func (f *fakePaypal) serve(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(r.Body)
	f.mu.Lock()
	f.requests = append(f.requests, paypalRequest{
		path: r.URL.Path, contentType: r.Header.Get("Content-Type"), accept: r.Header.Get("Accept"),
		acceptLanguage: r.Header.Get("Accept-Language"), authorization: r.Header.Get("Authorization"), body: string(body),
	})
	answer, held := f.answers[r.URL.Path], f.held
	f.mu.Unlock()
	if held != nil {
		select {
		case <-held:
		case <-r.Context().Done():
		}
	}
	if answer == nil {
		if conn, _, err := w.(http.Hijacker).Hijack(); err == nil {
			conn.Close()
		}
		return
	}
	w.Header().Set("Content-Type", answer.contentType)
	w.WriteHeader(answer.status)
	io.WriteString(w, answer.body)
}

func (f *fakePaypal) answer(path string, a *paypalAnswer) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.answers[path] = a
}

// hold keeps every request waiting until the test ends.
func (f *fakePaypal) hold(t *testing.T) {
	held := make(chan struct{})
	t.Cleanup(func() { close(held) })
	f.mu.Lock()
	defer f.mu.Unlock()
	f.held = held
}

func (f *fakePaypal) sent(path string) []paypalRequest {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []paypalRequest
	for _, r := range f.requests {
		if r.path == path {
			out = append(out, r)
		}
	}
	return out
}

func (f *fakePaypal) count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.requests)
}

func postPaypal(h *harness, contentType, body string, headers map[string]string) *httptest.ResponseRecorder {
	return h.post("/paypal-webhook", contentType, body, headers)
}

func postCapture(h *harness) *httptest.ResponseRecorder {
	capture := railsPaypalRequests["capture"]
	return postPaypal(h, capture.contentType, capture.body, rubyPaypalHeaders)
}

// noPaypalJob fails unless nothing reached a queue or the schedule.
func noPaypalJob(t *testing.T, h *harness, name string) {
	t.Helper()
	if h.jobs.Exists("queue:default") || h.jobs.Exists("schedule") {
		t.Errorf("%s: a job was enqueued", name)
	}
}

func TestPaypalWebhookEnqueuesAndVerifiesAsRailsDoes(t *testing.T) {
	immediate := map[string]bool{
		"capture": true, "raw characters": true, "unicode escapes": true, "dispute": true,
		"form with event_type": true, "empty json body": true, "text body": true,
		// The query's event_type wins over the body's, and isn't one PayPal sends.
		"merchant with query": false,
		"legacy ipn":          false,
	}
	for name, tc := range railsPaypalRequests {
		if tc.args == "" {
			continue
		}
		wantImmediate, ok := immediate[name]
		if !ok {
			t.Fatalf("%s: no expectation", name)
		}
		h := newHarness(t, nil)
		rec := h.post("/paypal-webhook"+tc.query, tc.contentType, tc.body, rubyPaypalHeaders)
		if rec.Code != http.StatusOK || rec.Body.String() != successJSON {
			t.Errorf("%s: got %d %s", name, rec.Code, rec.Body)
			continue
		}

		verifies := h.paypal.sent(paypalVerifyPath)
		switch {
		case tc.event == "" && len(verifies) != 0:
			t.Errorf("%s: verified a payload without an event_type", name)
		case tc.event != "" && len(verifies) != 1:
			t.Errorf("%s: %d verify calls", name, len(verifies))
		case tc.event != "" && verifies[0].body != rubyPaypalVerificationPrefix+tc.event+"}":
			t.Errorf("%s: verify body = %s\nwant          %s", name, verifies[0].body, rubyPaypalVerificationPrefix+tc.event+"}")
		}

		var arg string
		if wantImmediate {
			payloads, args := h.pushed(t, "default")
			if len(args) != 1 || h.jobs.Exists("schedule") {
				t.Errorf("%s: pushed %d, scheduled %v", name, len(args), h.jobs.Exists("schedule"))
				continue
			}
			if !strings.HasPrefix(payloads[0], `{"retry":5,"queue":"default","backtrace":true,"args":[`) || !strings.Contains(payloads[0], `"class":"HandlePaypalEventWorker"`) {
				t.Errorf("%s: payload = %s", name, payloads[0])
			}
			arg = args[0]
		} else {
			members, err := h.jobs.ZMembers("schedule")
			if err != nil || len(members) != 1 || h.jobs.Exists("queue:default") {
				t.Errorf("%s: schedule = %v, %v", name, members, err)
				continue
			}
			if score, _ := h.jobs.ZScore("schedule", members[0]); score != float64(h.now.UnixMicro())/1e6+600 {
				t.Errorf("%s: score = %f", name, score)
			}
			arg = onlyArg(t, members[0])
		}
		if arg != tc.args {
			t.Errorf("%s: arg = %s\nwant  %s", name, arg, tc.args)
		}
	}
}

func TestPaypalWebhookFetchesTheTokenOnceAndSharesItWithRails(t *testing.T) {
	h := newHarness(t, nil)
	for range 2 {
		if rec := postCapture(h); rec.Code != http.StatusOK {
			t.Fatalf("got %d %s", rec.Code, rec.Body)
		}
	}
	tokens := h.paypal.sent(paypalTokenPath)
	if len(tokens) != 1 {
		t.Fatalf("%d token requests", len(tokens))
	}
	basic := "Basic " + base64.StdEncoding.EncodeToString([]byte(paypalClientID+":"+paypalClientSecret))
	if got := tokens[0]; got.authorization != basic || got.body != "grant_type=client_credentials" ||
		got.contentType != "application/x-www-form-urlencoded" || got.accept != "application/json" || got.acceptLanguage != "en_US" {
		t.Errorf("token request = %+v", got)
	}
	for _, verify := range h.paypal.sent(paypalVerifyPath) {
		if verify.authorization != "Bearer A21AAtest" || verify.contentType != "application/json" {
			t.Errorf("verify request = %+v", verify)
		}
	}
	if got, _ := h.flags.Get(railsPaypalTokenKey); got != "Bearer A21AAtest" || h.flags.TTL(railsPaypalTokenKey) != 32400*time.Second {
		t.Errorf("cached %q for %v", got, h.flags.TTL(railsPaypalTokenKey))
	}

	// A token Rails cached is used as it is.
	h = newHarness(t, nil)
	h.flags.Set(railsPaypalTokenKey, "Bearer from-rails")
	postCapture(h)
	if verifies := h.paypal.sent(paypalVerifyPath); len(h.paypal.sent(paypalTokenPath)) != 0 || len(verifies) != 1 || verifies[0].authorization != "Bearer from-rails" {
		t.Errorf("token requests %d, verify %+v", len(h.paypal.sent(paypalTokenPath)), verifies)
	}
}

// expires_in.to_i: a Float truncates, and EXPIRE with 0 deletes the key Rails just set.
func TestPaypalWebhookCachesTheTokenForExpiresIn(t *testing.T) {
	for expiresIn, want := range map[string]time.Duration{`32400.9`: 32400 * time.Second, `"60"`: time.Minute, `0`: 0, `null`: 0} {
		h := newHarness(t, nil)
		h.paypal.answer(paypalTokenPath, &paypalAnswer{http.StatusOK, "application/json", `{"access_token":"A21AAtest","token_type":"Bearer","expires_in":` + expiresIn + `}`})
		if rec := postCapture(h); rec.Code != http.StatusOK {
			t.Fatalf("%s: got %d %s", expiresIn, rec.Code, rec.Body)
		}
		if got := h.flags.TTL(railsPaypalTokenKey); got != want || h.flags.Exists(railsPaypalTokenKey) != (want > 0) {
			t.Errorf("%s: cached for %v", expiresIn, got)
		}
	}
}

// valid? is false, a 400, wherever no answer arrives or the one that does isn't a pass.
func TestPaypalWebhookRejectsWhatPaypalDoesNotVerify(t *testing.T) {
	cases := map[string]struct {
		path               string
		answer             *paypalAnswer
		tokenTries, checks int
	}{
		"FAILURE":           {paypalVerifyPath, &paypalAnswer{http.StatusOK, "application/json", `{"verification_status":"FAILURE"}`}, 1, 1},
		"not a 200":         {paypalVerifyPath, &paypalAnswer{http.StatusInternalServerError, "application/json", `{"verification_status":"SUCCESS"}`}, 1, 1},
		"plain text":        {paypalVerifyPath, &paypalAnswer{http.StatusOK, "text/plain", `{"verification_status":"SUCCESS"}`}, 1, 1},
		"problem+json":      {paypalVerifyPath, &paypalAnswer{http.StatusOK, "application/problem+json", `{"verification_status":"SUCCESS"}`}, 1, 1},
		"a JSON string":     {paypalVerifyPath, &paypalAnswer{http.StatusOK, "application/json", `"SUCCESS"`}, 1, 1},
		"invalid JSON":      {paypalVerifyPath, &paypalAnswer{http.StatusOK, "application/json", `{"verification_status":`}, 1, 1},
		"verify hangs up":   {paypalVerifyPath, nil, 1, 1},
		"no token":          {paypalTokenPath, &paypalAnswer{http.StatusUnauthorized, "application/json", `{"error":"invalid_client"}`}, 1, 0},
		"token hangs up":    {paypalTokenPath, nil, 3, 0},
		"token is HTML":     {paypalTokenPath, &paypalAnswer{http.StatusOK, "text/html", "<html>"}, 1, 0},
		"token has no type": {paypalTokenPath, &paypalAnswer{http.StatusOK, "application/json", `{"access_token":"A21AAtest","expires_in":32400}`}, 1, 0},
	}
	for name, tc := range cases {
		h := newHarness(t, nil)
		h.paypal.answer(tc.path, tc.answer)
		rec := postCapture(h)
		if rec.Code != http.StatusBadRequest || rec.Body.String() != failureJSON {
			t.Errorf("%s: got %d %s", name, rec.Code, rec.Body)
		}
		if tries, checks := len(h.paypal.sent(paypalTokenPath)), len(h.paypal.sent(paypalVerifyPath)); tries != tc.tokenTries || checks != tc.checks {
			t.Errorf("%s: %d token requests, %d verify calls", name, tries, checks)
		}
		if !strings.Contains(h.logs.String(), "Rejected PayPal webhook because signature validation failed") {
			t.Errorf("%s: logs = %s", name, h.logs.String())
		}
		noPaypalJob(t, h, name)
	}
}

// HTTParty parses an empty body or null to nil, and nil, an Array or a number raise on
// ["field"], which valid? doesn't rescue.
func TestPaypalWebhookRaisesWherePaypalsAnswerRaisesInRails(t *testing.T) {
	cases := map[string]struct {
		path string
		body string
	}{
		"verify: empty":  {paypalVerifyPath, ""},
		"verify: null":   {paypalVerifyPath, "null"},
		"verify: array":  {paypalVerifyPath, `["SUCCESS"]`},
		"verify: number": {paypalVerifyPath, `1`},
		"token: array":   {paypalTokenPath, `[]`},
		"token: blank":   {paypalTokenPath, " \n"},
	}
	for name, tc := range cases {
		h := newHarness(t, nil)
		h.paypal.answer(tc.path, &paypalAnswer{http.StatusOK, "application/json", tc.body})
		if rec := postCapture(h); rec.Code != http.StatusInternalServerError {
			t.Errorf("%s: got %d %s", name, rec.Code, rec.Body)
		}
		noPaypalJob(t, h, name)
	}
}

func TestPaypalWebhookNeedsEveryPaypalHeader(t *testing.T) {
	capture := railsPaypalRequests["capture"]
	// PaypalWebhookVerifier::REQUIRED_HEADERS.
	for _, header := range []string{"Paypal-Transmission-Id", "Paypal-Transmission-Sig", "Paypal-Cert-Url", "Paypal-Auth-Algo", "Paypal-Transmission-Time"} {
		for _, value := range []string{"", " "} {
			h := newHarness(t, nil)
			headers := maps.Clone(rubyPaypalHeaders)
			if value == "" {
				delete(headers, header)
			} else {
				headers[header] = value
			}
			rec := postPaypal(h, capture.contentType, capture.body, headers)
			if rec.Code != http.StatusBadRequest || rec.Body.String() != failureJSON || h.paypal.count() != 0 {
				t.Errorf("%s %q: got %d %s, %d PayPal requests", header, value, rec.Code, rec.Body, h.paypal.count())
			}
			noPaypalJob(t, h, header)
		}
	}
}

// present? is false for these, so nothing is verified and the job waits ten minutes.
func TestPaypalWebhookSkipsVerificationForABlankEventType(t *testing.T) {
	for _, body := range []string{`{"event_type":" "}`, `{"event_type":false}`, `{"event_type":{}}`, `{"event_type":[]}`, `{"event_type":null}`} {
		h := newHarness(t, nil)
		rec := postPaypal(h, "application/json", body, nil)
		members, _ := h.jobs.ZMembers("schedule")
		if rec.Code != http.StatusOK || h.paypal.count() != 0 || len(members) != 1 {
			t.Errorf("%s: got %d %s, %d PayPal requests, scheduled %d", body, rec.Code, rec.Body, h.paypal.count(), len(members))
		}
	}
}

func TestPaypalWebhookAnswers503WhenTheTokenCacheFails(t *testing.T) {
	h := newHarness(t, nil)
	h.flags.SetError("ERR connection lost")
	if rec := postCapture(h); rec.Code != http.StatusServiceUnavailable || rec.Body.Len() != 0 || h.paypal.count() != 0 {
		t.Fatalf("got %d %q, %d PayPal requests", rec.Code, rec.Body, h.paypal.count())
	}
	noPaypalJob(t, h, "cache down")
}

func TestPaypalWebhookAnswers503WhenSidekiqRedisFails(t *testing.T) {
	h := newHarness(t, nil)
	h.jobs.SetError("ERR connection lost")
	if rec := postCapture(h); rec.Code != http.StatusServiceUnavailable || rec.Body.Len() != 0 {
		t.Fatalf("got %d %q", rec.Code, rec.Body)
	}
}

// Checks past the cap get a 503, which PayPal redelivers, before any PayPal call.
func TestPaypalWebhookAnswers503WhenEveryCallSlotIsBusy(t *testing.T) {
	h := newHarness(t, nil)
	slots := h.handlers.paypalVerifier.calls
	for range cap(slots) {
		slots <- struct{}{}
	}
	if rec := postCapture(h); rec.Code != http.StatusServiceUnavailable || rec.Body.Len() != 0 || h.paypal.count() != 0 {
		t.Fatalf("got %d %q, %d PayPal requests", rec.Code, rec.Body, h.paypal.count())
	}
	<-slots
	if rec := postCapture(h); rec.Code != http.StatusOK {
		t.Fatalf("with a slot free: got %d %s", rec.Code, rec.Body)
	}
	if len(slots) != cap(slots)-1 {
		t.Fatalf("the check kept its slot: %d of %d in use", len(slots), cap(slots))
	}
}

// Rails verifies, then perform_async raises from JSON.generate on the Infinity.
func TestPaypalWebhookRaisesWhereSidekiqCannotSerializeTheEvent(t *testing.T) {
	h := newHarness(t, nil)
	tc := railsPaypalRequests["infinity"]
	rec := postPaypal(h, tc.contentType, tc.body, rubyPaypalHeaders)
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("got %d %s", rec.Code, rec.Body)
	}
	if verifies := h.paypal.sent(paypalVerifyPath); len(verifies) != 1 || verifies[0].body != rubyPaypalVerificationPrefix+tc.event+"}" {
		t.Errorf("verify = %+v", verifies)
	}
	noPaypalJob(t, h, "infinity")
}

// JSON.parse keeps an unpaired low surrogate in a key, the params allow it, and to_json
// then raises once the token is in hand.
func TestPaypalWebhookRaisesWhereToJSONDoes(t *testing.T) {
	h := newHarness(t, nil)
	body := `{"event_type":"PAYMENT.CAPTURE.COMPLETED","k` + "\\" + `udc00":1}`
	rec := postPaypal(h, "application/json", body, rubyPaypalHeaders)
	if rec.Code != http.StatusInternalServerError || len(h.paypal.sent(paypalTokenPath)) != 1 || len(h.paypal.sent(paypalVerifyPath)) != 0 {
		t.Fatalf("got %d %s, %d PayPal requests", rec.Code, rec.Body, h.paypal.count())
	}
	noPaypalJob(t, h, "lone low")
}

// The action reads params first, so a body that doesn't parse is a 400 before any PayPal call.
func TestPaypalWebhookParsesTheParamsFirst(t *testing.T) {
	h := newHarness(t, nil)
	rec := postPaypal(h, "application/json", `{"event_type":`, rubyPaypalHeaders)
	if rec.Code != http.StatusBadRequest || rec.Body.Len() != 0 || h.paypal.count() != 0 {
		t.Fatalf("got %d %q, %d PayPal requests", rec.Code, rec.Body, h.paypal.count())
	}
	noPaypalJob(t, h, "truncated")
}

func TestPaypalWebhookGivesUpOnASlowPaypal(t *testing.T) {
	h := newHarness(t, nil)
	h.handlers.paypalVerifier.timeout = 50 * time.Millisecond
	h.paypal.hold(t)
	if rec := postCapture(h); rec.Code != http.StatusBadRequest || rec.Body.String() != failureJSON {
		t.Fatalf("got %d %s", rec.Code, rec.Body)
	}
	noPaypalJob(t, h, "slow")
}

func TestPaypalWebhookNeedsAllThreeSettings(t *testing.T) {
	for name, clear := range map[string]func(*Deps){
		"PAYPAL_WEBHOOK_ID":            func(d *Deps) { d.PaypalWebhookID = " " },
		"PAYPAL_PARTNER_CLIENT_ID":     func(d *Deps) { d.PaypalPartnerClientID = "" },
		"PAYPAL_PARTNER_CLIENT_SECRET": func(d *Deps) { d.PaypalPartnerClientSecret = "" },
	} {
		h := newHarness(t, clear)
		if rec := postPaypal(h, "application/json", "{}", nil); rec.Code != http.StatusNotFound {
			t.Errorf("without %s: got %d", name, rec.Code)
		}
	}
}

// PAYPAL_REST_ENDPOINT follows Rails.env.production?.
func TestPaypalVerifierCallsTheEndpointRailsDoes(t *testing.T) {
	deps := Deps{Env: newHarness(t, nil).handlers.env, PaypalWebhookID: "id", PaypalPartnerClientID: "client", PaypalPartnerClientSecret: "secret"}
	if v := newPaypalVerifier(deps); v.api != "https://api.paypal.com" {
		t.Errorf("production: %s", v.api)
	}
	staging := *deps.Env
	staging.Name = "staging"
	deps.Env = &staging
	if v := newPaypalVerifier(deps); v.api != "https://api.sandbox.paypal.com" {
		t.Errorf("staging: %s", v.api)
	}
}

// paypalImmediateEvents and paypalDelay copy PaypalEventType and PaypalEventHandler.
func TestPaypalSchedulingMatchesTheRubySource(t *testing.T) {
	types, err := os.ReadFile("../../../app/business/payments/events/paypal/paypal_event_type.rb")
	if err != nil {
		t.Fatal(err)
	}
	values := map[string]string{}
	for _, m := range regexp.MustCompile(`(?m)^\s*([A-Z_]+) = "([^"]+)"$`).FindAllStringSubmatch(string(types), -1) {
		values[m[1]] = m[2]
	}
	ruby := map[string]bool{}
	for _, m := range regexp.MustCompile(`(?s)(?:ORDER_API_EVENTS|MERCHANT_ACCOUNT_EVENTS) = \[(.*?)\]`).FindAllStringSubmatch(string(types), -1) {
		for _, name := range strings.Split(m[1], ",") {
			value, ok := values[strings.TrimSpace(name)]
			if !ok {
				t.Fatalf("no constant %q", strings.TrimSpace(name))
			}
			ruby[value] = true
		}
	}
	if len(ruby) != len(paypalImmediateEvents) {
		t.Errorf("Ruby enqueues %d event types at once, Go %d", len(ruby), len(paypalImmediateEvents))
	}
	for value := range ruby {
		if !paypalImmediateEvents[value] {
			t.Errorf("%s is missing from paypalImmediateEvents", value)
		}
	}

	handler, err := os.ReadFile("../../../app/business/payments/events/paypal/paypal_event_handler.rb")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(handler), "HandlePaypalEventWorker.perform_in(10.minutes, paypal_event)") || paypalDelay != 10*time.Minute {
		t.Error("PaypalEventHandler no longer waits ten minutes")
	}
}
