package licenses

import (
	"bytes"
	"database/sql"
	"io"
	"log/slog"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"

	"github.com/antiwork/gumroad/go_web/internal/obfuscate"
	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/web"
)

// testNow is the clock the handler sees; fixtures are dated relative to it.
var testNow = time.Date(2026, 11, 2, 12, 0, 0, 0, time.UTC)

type harness struct {
	app     *web.App
	handler *handler
	redis   *miniredis.Miniredis // $redis
	sidekiq *miniredis.Miniredis
	ids     *obfuscate.IDs
	logs    *bytes.Buffer
}

func newHarness(t *testing.T, db *sql.DB, vars map[string]string) *harness {
	t.Helper()
	getenv := func(name string) string {
		if v, ok := vars[name]; ok {
			return v
		}
		return map[string]string{"RAILS_ENV": "production", "REVISION": "rev"}[name]
	}
	env, err := web.LoadEnvironment(getenv)
	if err != nil {
		t.Fatal(err)
	}
	ids, err := obfuscate.New("test", "1234")
	if err != nil {
		t.Fatal(err)
	}
	h := &harness{redis: miniredis.RunT(t), sidekiq: miniredis.RunT(t), ids: ids, logs: &bytes.Buffer{}}
	redisClient := redis.NewClient(&redis.Options{Addr: h.redis.Addr(), MaxRetries: -1})
	sidekiqClient := redis.NewClient(&redis.Options{Addr: h.sidekiq.Addr(), MaxRetries: -1})
	t.Cleanup(func() { redisClient.Close(); sidekiqClient.Close() })
	logger := slog.New(slog.NewJSONHandler(h.logs, nil))
	h.app = web.NewApp(env, logger, redisClient)
	h.handler = register(h.app, Deps{Env: env, Stack: rails.NewStack(env, getenv("CUSTOM_DOMAIN")), DB: db, Redis: redisClient,
		SidekiqRedis: sidekiqClient, IDs: ids}, func() time.Time { return testNow })
	return h
}

type request struct {
	host        string
	target      string
	contentType string
	body        string
	headers     map[string]string
}

func (h *harness) do(t *testing.T, req request) *httptest.ResponseRecorder {
	t.Helper()
	if req.host == "" {
		req.host = "api.gumroad.com"
	}
	if req.target == "" {
		req.target = "/v2/licenses/verify"
	}
	r := httptest.NewRequest("POST", req.target, strings.NewReader(req.body))
	r.Host = req.host
	if req.contentType != "" {
		r.Header.Set("Content-Type", req.contentType)
	}
	for k, v := range req.headers {
		r.Header.Set(k, v)
	}
	w := httptest.NewRecorder()
	h.app.ServeHTTP(w, r)
	return w
}

func (h *harness) form(t *testing.T, body string) *httptest.ResponseRecorder {
	t.Helper()
	return h.do(t, request{contentType: "application/x-www-form-urlencoded", body: body})
}

func readBody(t *testing.T, w *httptest.ResponseRecorder) string {
	t.Helper()
	b, err := io.ReadAll(w.Result().Body)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func expectResponse(t *testing.T, w *httptest.ResponseRecorder, status int, body string) {
	t.Helper()
	if got := readBody(t, w); w.Code != status || got != body {
		t.Fatalf("got %d\n%s\nwant %d\n%s", w.Code, got, status, body)
	}
}

func expectHeader(t *testing.T, w *httptest.ResponseRecorder, name, want string) {
	t.Helper()
	if got := strings.Join(w.Header().Values(name), "|"); got != want {
		t.Errorf("%s = %q, want %q", name, got, want)
	}
}

func nullStr(s string) sql.NullString { return sql.NullString{String: s, Valid: true} }
