package webhooks

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"

	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/sidekiq"
	"github.com/antiwork/gumroad/go_web/internal/web"
)

type harness struct {
	app      *web.App
	handlers *handlers
	flags    *miniredis.Miniredis // REDIS_HOST: Flipper's flags and the PayPal token
	jobs     *miniredis.Miniredis // SIDEKIQ_REDIS_HOST
	certs    *fakeCertHost
	paypal   *fakePaypal
	logs     *bytes.Buffer
	now      time.Time
}

// newHarness wires the package as main.go would, with every secret set unless edit
// clears it.
func newHarness(t *testing.T, edit func(*Deps)) *harness {
	t.Helper()
	env, err := web.LoadEnvironment(func(name string) string {
		return map[string]string{"RAILS_ENV": "production", "REVISION": "r"}[name]
	})
	if err != nil {
		t.Fatal(err)
	}
	h := &harness{flags: miniredis.RunT(t), jobs: miniredis.RunT(t), certs: rubyCertHost(), logs: &bytes.Buffer{}, now: rubyStripeSignedAt}
	appRedis := miniredis.RunT(t)
	clients := []*redis.Client{
		redis.NewClient(&redis.Options{Addr: appRedis.Addr()}),
		redis.NewClient(&redis.Options{Addr: h.flags.Addr(), MaxRetries: -1}),
		redis.NewClient(&redis.Options{Addr: h.jobs.Addr(), MaxRetries: -1}),
	}
	t.Cleanup(func() {
		for _, c := range clients {
			c.Close()
		}
	})
	logger := slog.New(slog.NewJSONHandler(h.logs, nil))
	stack := rails.NewStack(env, "")
	h.app = web.NewApp(env, logger, clients[0])
	h.app.HandleNotFound(stack.NotFound())
	deps := Deps{
		Env:                         env,
		Stack:                       stack,
		Redis:                       clients[1],
		Sidekiq:                     &sidekiq.Client{Redis: clients[2], Now: func() time.Time { return h.now }},
		StripeEndpointSecret:        rubyStripeSecret,
		StripeConnectEndpointSecret: rubyStripeSecret,
		PaypalWebhookID:             rubyPaypalWebhookID,
		PaypalPartnerClientID:       paypalClientID,
		PaypalPartnerClientSecret:   paypalClientSecret,
		SendgridPublicKeys:          []string{"", rubySendgridKey1, "", rubySendgridKey2, ""},
		Logger:                      logger,
		Now:                         func() time.Time { return h.now },
	}
	if edit != nil {
		edit(&deps)
	}
	if h.handlers, err = register(h.app, deps, h.certs.get); err != nil {
		t.Fatal(err)
	}
	// No test reaches the real PayPal.
	if v := h.handlers.paypalVerifier; v != nil {
		h.paypal = newFakePaypal(t)
		v.api, v.retryWait = h.paypal.server.URL, 0
	}
	return h
}

func (h *harness) post(path, contentType, body string, headers map[string]string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodPost, path, strings.NewReader(body))
	req.Host = "gumroad.com"
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	for name, value := range headers {
		req.Header.Set(name, value)
	}
	rec := httptest.NewRecorder()
	h.app.ServeHTTP(rec, req)
	return rec
}

// pushed returns each job on queue, oldest first, and its single argument's bytes.
func (h *harness) pushed(t *testing.T, queue string) (payloads []string, args []string) {
	t.Helper()
	if !h.jobs.Exists("queue:" + queue) {
		return nil, nil
	}
	list, err := h.jobs.List("queue:" + queue)
	if err != nil {
		t.Fatal(err)
	}
	for i := len(list) - 1; i >= 0; i-- {
		payloads = append(payloads, list[i])
		args = append(args, onlyArg(t, list[i]))
	}
	return payloads, args
}

func onlyArg(t *testing.T, payload string) string {
	t.Helper()
	var job struct{ Args []json.RawMessage }
	if err := json.Unmarshal([]byte(payload), &job); err != nil || len(job.Args) != 1 {
		t.Fatalf("payload %s: %v", payload, err)
	}
	return string(job.Args[0])
}

func (h *harness) logLines(t *testing.T) []map[string]any {
	t.Helper()
	var lines []map[string]any
	for _, raw := range bytes.Split(bytes.TrimSpace(h.logs.Bytes()), []byte("\n")) {
		if len(raw) == 0 {
			continue
		}
		var line map[string]any
		if err := json.Unmarshal(raw, &line); err != nil {
			t.Fatal(err)
		}
		lines = append(lines, line)
	}
	return lines
}

func TestRegisterLeavesARouteWithoutItsSecretsToRails(t *testing.T) {
	h := newHarness(t, func(d *Deps) {
		d.StripeEndpointSecret, d.StripeConnectEndpointSecret, d.SendgridPublicKeys = " ", "", []string{"", " "}
		d.PaypalWebhookID = ""
	})
	for _, path := range []string{"/stripe-webhook", "/stripe-connect-webhook", "/paypal-webhook", "/sendgrid-webhook"} {
		if rec := h.post(path, "application/json", "{}", nil); rec.Code != http.StatusNotFound {
			t.Errorf("%s: got %d", path, rec.Code)
		}
	}
	// The SNS routes need no secret.
	if rec := h.post("/sns-mediaconvert-webhook", "text/plain", "null", nil); rec.Code != http.StatusBadRequest {
		t.Errorf("SNS: got %d", rec.Code)
	}
	for _, want := range []string{"/stripe-webhook is not served", "/stripe-connect-webhook is not served", "/paypal-webhook is not served", "/sendgrid-webhook is not served"} {
		if n := strings.Count(h.logs.String(), want); n != 1 {
			t.Errorf("want one warning containing %q, got %d", want, n)
		}
	}
}

func TestRegisterRequiresItsDependencies(t *testing.T) {
	if err := Register(newHarness(t, nil).app, Deps{}); err == nil {
		t.Fatal("Register accepted missing dependencies")
	}
}

func TestEachRouteLogsItsRailsAction(t *testing.T) {
	h := newHarness(t, nil)
	routes := map[string]string{
		"/stripe-webhook":           "stripe",
		"/stripe-connect-webhook":   "stripe_connect",
		"/paypal-webhook":           "paypal",
		"/sendgrid-webhook":         "sendgrid",
		"/sns-mediaconvert-webhook": "mediaconvert",
		"/sns-aws-config-webhook":   "sns_aws_config",
	}
	for path, action := range routes {
		h.logs.Reset()
		h.post(path, "text/plain", "x", nil)
		var found bool
		for _, line := range h.logLines(t) {
			if line["msg"] == "request" && line["path"] == path {
				found = line["controller"] == "ForeignWebhooksController" && line["action"] == action
			}
		}
		if !found {
			t.Errorf("%s: no access line for ForeignWebhooksController#%s in %s", path, action, h.logs.String())
		}
	}
}

// The routes sit inside GumroadDomainConstraint, VALID_REQUEST_HOSTS.
func TestOnlyTheGumroadHostsAreRouted(t *testing.T) {
	h := newHarness(t, nil)
	for host, want := range map[string]int{
		"gumroad.com":        http.StatusOK,
		"app.gumroad.com":    http.StatusOK,
		"seller.gumroad.com": http.StatusNotFound,
		"api.gumroad.com":    http.StatusNotFound,
		"example.com":        http.StatusNotFound,
	} {
		req := httptest.NewRequest(http.MethodPost, "/stripe-webhook", strings.NewReader(rubyStripePayload))
		req.Host = host
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Stripe-Signature", rubyStripeHeader)
		rec := httptest.NewRecorder()
		h.app.ServeHTTP(rec, req)
		if rec.Code != want {
			t.Errorf("%s: got %d, want %d", host, rec.Code, want)
		}
	}
}

func TestOnlyPostIsRouted(t *testing.T) {
	h := newHarness(t, nil)
	req := httptest.NewRequest(http.MethodGet, "/stripe-webhook", nil)
	req.Host = "gumroad.com"
	rec := httptest.NewRecorder()
	h.app.ServeHTTP(rec, req)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("GET: got %d", rec.Code)
	}
}

// The stack's rejections come before any filter, so they win over a bad signature,
// whose answer would be {"success":false}.
func TestTheRackStackAnswersFirst(t *testing.T) {
	h := newHarness(t, nil)
	cases := map[string]struct {
		path, contentType, body string
		status                  int
		responseType            string
	}{
		// CatchBadRequestErrors' empty text/html.
		"bad query escape": {"/stripe-webhook?a=%zz", "application/json", "{}", http.StatusBadRequest, "text/html"},
		// JSON.parse keeps \udc00 as a string that isn't UTF-8, which check_param_encoding refuses.
		"lone low surrogate": {"/stripe-webhook", "application/json", `{"id":"\udc00"}`, http.StatusBadRequest, "text/html"},
		"invalid media type": {"/sendgrid-webhook", "garbage", "[]", http.StatusNotAcceptable, "text/html; charset=utf-8"},
		"over the cap":       {"/sns-aws-config-webhook", "text/plain", strings.Repeat("x", maxBodyBytes+1), http.StatusRequestEntityTooLarge, ""},
	}
	for name, tc := range cases {
		rec := h.post(tc.path, tc.contentType, tc.body, map[string]string{"Stripe-Signature": "invalid"})
		if rec.Code != tc.status || rec.Body.Len() != 0 || rec.Header().Get("Content-Type") != tc.responseType {
			t.Errorf("%s: got %d %q %q", name, rec.Code, rec.Header().Get("Content-Type"), rec.Body)
		}
	}
}

// Rails' perform_async raises from JSON.generate on these, a 500; SNS leaves unsigned
// fields to the sender.
func TestAJobSidekiqCannotSerializeIsA500(t *testing.T) {
	nested := func(n int) string { return strings.Repeat("[", n) + strings.Repeat("]", n) }
	notification := func(extra string) string {
		return strings.TrimSuffix(rubySNSNotificationV1, "}") + `,"Extra":` + extra + `}`
	}
	cases := map[string]struct {
		extra  string
		status int
	}{
		"Infinity":                       {"1e400", http.StatusInternalServerError},
		"past JSON.generate's nesting":   {nested(98), http.StatusInternalServerError},
		"inside JSON.generate's nesting": {nested(97), http.StatusOK},
	}
	for name, tc := range cases {
		h := newHarness(t, nil)
		rec := h.post("/sns-aws-config-webhook", "text/plain", notification(tc.extra), nil)
		if _, args := h.pushed(t, "low"); rec.Code != tc.status || (len(args) == 1) != (tc.status == http.StatusOK) {
			t.Errorf("%s: got %d, pushed %d", name, rec.Code, len(args))
		}
	}
}

// Every provider here retries a 5xx, so a full budget sheds load with an empty 503.
func TestTheInFlightBudgetAnswers503WhenFull(t *testing.T) {
	h := newHarness(t, nil)
	h.handlers.inFlight = newBudget(minRequestWeight)
	for range 3 {
		if rec := postStripe(h, "/stripe-webhook", rubyStripeHeader, rubyStripePayload); rec.Code != http.StatusOK {
			t.Fatalf("within the budget: got %d, so a request didn't release its share", rec.Code)
		}
	}
	h.handlers.inFlight.used = 1
	rec := postStripe(h, "/stripe-webhook", rubyStripeHeader, rubyStripePayload)
	if rec.Code != http.StatusServiceUnavailable || rec.Body.Len() != 0 {
		t.Fatalf("past the budget: got %d %q", rec.Code, rec.Body)
	}
	if _, args := h.pushed(t, "default"); len(args) != 3 {
		t.Fatalf("pushed %d", len(args))
	}
}

func TestAChunkedBodyOverTheCapIsA413(t *testing.T) {
	h := newHarness(t, nil)
	req := httptest.NewRequest(http.MethodPost, "/sendgrid-webhook", strings.NewReader(strings.Repeat("x", maxLargeBodyBytes+1)))
	req.Host, req.ContentLength = "gumroad.com", -1
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h.app.ServeHTTP(rec, req)
	if rec.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("got %d", rec.Code)
	}
	// Rails took up to nginx's 10M, so each one is a delivery Go refused.
	var logged bool
	for _, line := range h.logLines(t) {
		logged = logged || line["level"] == "ERROR" && line["action"] == "sendgrid" && line["content_length"] == -1.0
	}
	if !logged {
		t.Fatalf("no error line in %s", h.logs.String())
	}
}

// The body is read as it arrives, never into a buffer the declared length sizes.
func TestADeclaredLengthLongerThanTheBodyIsA400(t *testing.T) {
	h := newHarness(t, nil)
	server := httptest.NewServer(h.app)
	defer server.Close()
	conn, err := net.Dial("tcp", server.Listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	fmt.Fprintf(conn, "POST /stripe-webhook HTTP/1.1\r\nHost: gumroad.com\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n{}", maxLargeBodyBytes)
	conn.(*net.TCPConn).CloseWrite()
	resp, err := http.ReadResponse(bufio.NewReader(conn), nil)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("got %d", resp.StatusCode)
	}
}
