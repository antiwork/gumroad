package web

import (
	"bytes"
	"encoding/json"
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
