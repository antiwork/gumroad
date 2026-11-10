package web

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"
)

func testEnvironment(t *testing.T) *Environment {
	t.Helper()
	env, err := LoadEnvironment(func(name string) string {
		return map[string]string{"RAILS_ENV": "production", "REVISION": "abc123"}[name]
	})
	if err != nil {
		t.Fatal(err)
	}
	return env
}

func TestHostPrefersTheLastForwardedHostAndDropsThePort(t *testing.T) {
	r := httptest.NewRequest("GET", "/robots.txt", nil)
	r.Host = "origin.example.com:8080"
	if got := Host(r); got != "origin.example.com" {
		t.Fatalf("Host = %q", got)
	}
	r.Header.Set("X-Forwarded-Host", "first.example.com, seller.gumroad.com:443")
	if got := Host(r); got != "seller.gumroad.com" {
		t.Fatalf("Host = %q", got)
	}
	// Ruby's split drops the trailing empty field.
	r.Header.Set("X-Forwarded-Host", "seller.gumroad.com,")
	if got := Host(r); got != "seller.gumroad.com" {
		t.Fatalf("Host = %q", got)
	}
}

func TestFullpathKeepsTheQueryOnlyWhenThereIsOne(t *testing.T) {
	for uri, want := range map[string]string{"/a": "/a", "/a?": "/a", "/a?b=1": "/a?b=1", "/%7Euser": "/%7Euser"} {
		r := httptest.NewRequest("GET", uri, nil)
		if got := Fullpath(r); got != want {
			t.Errorf("Fullpath(%q) = %q, want %q", uri, got, want)
		}
	}
}

func TestLoadEnvironmentAddsCustomDomainHosts(t *testing.T) {
	env, err := LoadEnvironment(func(name string) string {
		return map[string]string{"RAILS_ENV": "staging", "REVISION": "r", "CUSTOM_DOMAIN": "preview.example.com", "BRANCH_DEPLOYMENT": "true"}[name]
	})
	if err != nil {
		t.Fatal(err)
	}
	if !env.IsGumroadHost("preview.example.com") || env.IsGumroadHost("seller.staging.gumroad.com") {
		t.Fatalf("ValidRequestHosts = %v", env.ValidRequestHosts)
	}
	if got := env.ValidAPIRequestHosts; len(got) != 3 || got[1] != "api.preview.example.com" || got[2] != "preview.example.com" {
		t.Fatalf("ValidAPIRequestHosts = %v", got)
	}
}

func TestLoadEnvironmentRequiresARevisionWhereRailsDoes(t *testing.T) {
	_, err := LoadEnvironment(func(name string) string { return map[string]string{"RAILS_ENV": "production"}[name] })
	if err == nil {
		t.Fatal("expected an error without REVISION")
	}
}

func TestParseSubdomainRedirectsMatchesTheRailsParser(t *testing.T) {
	config := " Seller.Gumroad.com/old = https://example.com/new \n\nnovalue=\n=nohost\ngumroad.com=https://evil.example\nbroken line\nother.gumroad.com=https://a=b\n"
	got := parseSubdomainRedirects(config, map[string]bool{"gumroad.com": true})
	want := map[string]string{"seller.gumroad.com/old": "https://example.com/new", "other.gumroad.com": "https://a=b"}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%q => %q, want %q", k, got[k], v)
		}
	}
}

func newTestApp(t *testing.T, config string) (*App, *bytes.Buffer) {
	t.Helper()
	server := miniredis.RunT(t)
	if config != "" {
		server.Set(subdomainRedirectsKey, config)
	}
	client := redis.NewClient(&redis.Options{Addr: server.Addr()})
	t.Cleanup(func() { client.Close() })
	logs := &bytes.Buffer{}
	logger := slog.New(slog.NewJSONHandler(logs, nil))
	env := testEnvironment(t)
	app := NewApp(env, logger, client)
	app.Handle("GET /robots.txt", "RobotsController#index", http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		io.WriteString(w, "ok")
	}))
	return app, logs
}

// An unclean path under a registered prefix reaches its handler; every other request goes to
// the mux, which redirects an unclean one.
func TestAppSendsUncleanPathsUnderAPrefixToTheirHandler(t *testing.T) {
	app, _ := newTestApp(t, "")
	write := func(body string) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { io.WriteString(w, body) })
	}
	app.HandlePage("GET /l/{id}", "LinksController#show", write("page"))
	app.HandlePage("GET /l/{id}/{rest...}", "LinksController#show", write("page"))
	app.HandleUncleanPage("/l/", "LinksController#show", write("unclean"))
	for _, c := range []struct{ method, target, want string }{
		{"GET", "/l/a", "page"},
		{"GET", "/l/a/", "page"},
		{"GET", "/l/a//b", "unclean"},
		{"GET", "/l/./a", "unclean"},
		{"GET", "/l/a/../b", "unclean"},
		// The mux checks the escaped path, where these are no slash or dot segment.
		{"GET", "/l/a%2F%2Fb", "page"},
		{"GET", "/l/%2e%2e/b", "page"},
		{"CONNECT", "/l/a//b", "mux"},
		{"GET", "/robots.txt//", "redirect"},
	} {
		w := httptest.NewRecorder()
		app.ServeHTTP(w, httptest.NewRequest(c.method, c.target, nil))
		body := w.Body.String()
		switch c.want {
		case "mux":
			if body == "unclean" {
				t.Errorf("%s %s reached the unclean handler", c.method, c.target)
			}
		case "redirect":
			if w.Code < 300 || w.Code > 399 || body == "unclean" {
				t.Errorf("%s %s: %d %q", c.method, c.target, w.Code, body)
			}
		default:
			if body != c.want {
				t.Errorf("%s %s: %d %q, want %q", c.method, c.target, w.Code, body, c.want)
			}
		}
	}
}

func TestAppRedirectsConfiguredHostPathsBeforeTheAction(t *testing.T) {
	app, _ := newTestApp(t, "seller.gumroad.com/robots.txt=https://example.com/robots.txt\nother.gumroad.com/robots.txt=/elsewhere\nthird.gumroad.com/robots.txt=elsewhere")

	r := httptest.NewRequest("GET", "/robots.txt", nil)
	r.Host = "seller.gumroad.com"
	w := httptest.NewRecorder()
	app.ServeHTTP(w, r)
	if w.Code != http.StatusFound || w.Header().Get("Location") != "https://example.com/robots.txt" || w.Body.Len() != 0 {
		t.Fatalf("got %d %q %q", w.Code, w.Header().Get("Location"), w.Body.String())
	}
	if got := w.Header().Get("Cache-Control"); got != "no-cache" {
		t.Fatalf("Cache-Control = %q", got)
	}

	r = httptest.NewRequest("GET", "/robots.txt", nil)
	r.Host = "other.gumroad.com"
	r.Header.Set("X-Forwarded-Proto", "https")
	w = httptest.NewRecorder()
	app.ServeHTTP(w, r)
	if got := w.Header().Get("Location"); got != "https://other.gumroad.com/elsewhere" {
		t.Fatalf("Location = %q", got)
	}

	// Rails 8.1 raises on a path-relative redirect.
	r = httptest.NewRequest("GET", "/robots.txt", nil)
	r.Host = "third.gumroad.com"
	w = httptest.NewRecorder()
	app.ServeHTTP(w, r)
	if w.Code != http.StatusInternalServerError {
		t.Fatalf("path-relative redirect: status %d", w.Code)
	}

	r = httptest.NewRequest("GET", "/robots.txt?x=1", nil)
	r.Host = "seller.gumroad.com"
	w = httptest.NewRecorder()
	app.ServeHTTP(w, r)
	if w.Code != http.StatusOK || w.Body.String() != "ok" {
		t.Fatalf("a different fullpath must not redirect, got %d", w.Code)
	}
}

func TestAppLogsOneLinePerActionAndSetsDebugHeaders(t *testing.T) {
	app, logs := newTestApp(t, "")
	r := httptest.NewRequest("GET", "/robots.txt", nil)
	r.Host = "seller.gumroad.com"
	r.Header.Set("X-Request-Id", "req<1>")
	w := httptest.NewRecorder()
	app.ServeHTTP(w, r)

	if w.Header().Get("X-Request-Id") != "req1" || w.Header().Get("X-Revision") != "abc123" || w.Header().Get("X-GR") != "PROD" {
		t.Fatalf("headers = %v", w.Header())
	}
	var line map[string]any
	if err := json.Unmarshal(logs.Bytes(), &line); err != nil {
		t.Fatalf("log %q: %v", logs.String(), err)
	}
	if line["controller"] != "RobotsController" || line["action"] != "index" || line["status"] != float64(200) || line["host"] != "seller.gumroad.com" {
		t.Fatalf("log line = %v", line)
	}

	logs.Reset()
	app.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest("GET", "/healthcheck", nil))
	if logs.Len() != 0 {
		t.Fatalf("healthcheck logged %q", logs.String())
	}
}

func TestAppRecoversFromAPanickingAction(t *testing.T) {
	app, _ := newTestApp(t, "")
	app.Handle("GET /boom", "BoomController#show", http.HandlerFunc(func(http.ResponseWriter, *http.Request) { panic("boom") }))
	w := httptest.NewRecorder()
	app.ServeHTTP(w, httptest.NewRequest("GET", "/boom", nil))
	if w.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d", w.Code)
	}
}

// A query cut short by the client's disconnect fails with the request's own cancellation,
// sometimes joined to the I/O error it caused.
func TestClientLeftLogsTheRequestAs499(t *testing.T) {
	for _, tc := range []struct {
		name string
		err  func(ctx context.Context) error
		left bool
	}{
		{"cancellation", func(ctx context.Context) error { return ctx.Err() }, true},
		{"joined", func(ctx context.Context) error { return errors.Join(errors.New("read tcp: i/o timeout"), ctx.Err()) }, true},
		{"unrelated", func(context.Context) error { return errors.New("Unknown column") }, false},
	} {
		app, logs := newTestApp(t, "")
		app.Handle("GET /l/{id}", "LinksController#show", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if !ClientLeft(w, r, tc.err(r.Context())) {
				InternalServerError(w)
			}
		}))
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		app.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest("GET", "/l/abc", nil).WithContext(ctx))
		var status float64
		for line := range bytes.Lines(logs.Bytes()) {
			var l map[string]any
			if err := json.Unmarshal(line, &l); err == nil && l["msg"] == "request" {
				status = l["status"].(float64)
			}
		}
		if want := map[bool]float64{true: statusClientClosedRequest, false: http.StatusInternalServerError}[tc.left]; status != want {
			t.Errorf("%s: logged %v, want %v", tc.name, status, want)
		}
	}
}

func TestWriteCacheableAnswersAMatchingETagWithAnEmpty304(t *testing.T) {
	// Rack::ETag: W/ plus the first 32 hex digits of the body's SHA-256.
	etag := `W/"230d8358dc8e8890b4c58deeb62912ee"`
	if got := ETag("body"); got != etag {
		t.Fatalf("ETag = %q", got)
	}
	w := httptest.NewRecorder()
	WriteCacheable(w, httptest.NewRequest("GET", "/", nil), TextPlain, etag, "body")
	if w.Code != http.StatusOK || w.Header().Get("ETag") != etag || w.Body.String() != "body" || w.Header().Get("Content-Length") != "4" {
		t.Fatalf("got %d %q %q", w.Code, w.Header().Get("ETag"), w.Body.String())
	}

	r := httptest.NewRequest("GET", "/", nil)
	r.Header.Set("If-None-Match", etag)
	w = httptest.NewRecorder()
	WriteCacheable(w, r, TextPlain, etag, "body")
	if w.Code != http.StatusNotModified || w.Body.Len() != 0 || w.Header().Get("Content-Type") != "" {
		t.Fatalf("got %d %q %q", w.Code, w.Body.String(), w.Header().Get("Content-Type"))
	}
}

func TestHTMLEscapeMatchesERBUtil(t *testing.T) {
	if got := HTMLEscape(`<a href="x">'&'</a>`); got != "&lt;a href=&quot;x&quot;&gt;&#39;&amp;&#39;&lt;/a&gt;" {
		t.Fatalf("got %q", got)
	}
}

func TestAppHandsUnmatchedRequestsToNotFound(t *testing.T) {
	app, _ := newTestApp(t, "")
	app.HandleNotFound(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNotFound)
		io.WriteString(w, "rails 404")
	}))
	for _, c := range []struct{ method, path string }{{"GET", "/missing"}, {"POST", "/robots.txt"}} {
		w := httptest.NewRecorder()
		app.ServeHTTP(w, httptest.NewRequest(c.method, c.path, nil))
		if w.Code != http.StatusNotFound || w.Body.String() != "rails 404" || w.Header().Get("X-Revision") != "abc123" {
			t.Errorf("%s %s: %d %q %v", c.method, c.path, w.Code, w.Body.String(), w.Header())
		}
	}
	w := httptest.NewRecorder()
	app.ServeHTTP(w, httptest.NewRequest("GET", "/robots.txt", nil))
	if w.Code != http.StatusOK {
		t.Errorf("a matched route still reaches its handler: %d", w.Code)
	}
}

func TestLastListEntryMatchesRubySplit(t *testing.T) {
	// Expected values from `value.split(/,\s?/).last` in Ruby.
	for value, want := range map[string]string{
		"a.com":            "a.com",
		"a.com, b.com":     "b.com",
		"a.com,b.com":      "b.com",
		"a.com,":           "a.com",
		"a.com, ":          "a.com",
		"a.com,,":          "a.com",
		"a.com,  b.com":    " b.com",
		"a.com,\tb.com":    "b.com",
		",a.com":           "a.com",
		"a.com, b.com, , ": "b.com",
	} {
		if got := lastListEntry([]string{value}); got != want {
			t.Errorf("lastListEntry(%q) = %q, want %q", value, got, want)
		}
	}
}
