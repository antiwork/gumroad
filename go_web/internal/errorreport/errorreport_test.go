package errorreport_test

import (
	"bytes"
	"encoding/json"
	"log/slog"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/getsentry/sentry-go"

	"github.com/antiwork/gumroad/go_web/internal/errorreport"
)

func newTestLogger(t *testing.T) (*slog.Logger, *bytes.Buffer, *sentry.MockTransport) {
	t.Helper()
	sent := &sentry.MockTransport{}
	client, err := sentry.NewClient(sentry.ClientOptions{Dsn: "https://public@example.com/1", Transport: sent})
	if err != nil {
		t.Fatal(err)
	}
	var logs bytes.Buffer
	h := errorreport.NewHandlerWithHub(slog.NewJSONHandler(&logs, nil), sentry.NewHub(client, sentry.NewScope()))
	return slog.New(h), &logs, sent
}

func TestErrorLinesAreReportedWithTheirRequestAndCallSite(t *testing.T) {
	logger, logs, sent := newTestLogger(t)
	r := httptest.NewRequest("GET", "/l/abc?wanted=true", nil)
	r.Host = "seller.gumroad.com"
	r.Header.Set("Cookie", "_gumroad_app_session=secret")
	logger.With("uuid", "req-1", errorreport.Request(r, "req-1")).Error("product page failed", "error", "Unknown column")

	events := sent.Events()
	if len(events) != 1 {
		t.Fatalf("%d events", len(events))
	}
	e := events[0]
	if e.Message != "product page failed" || e.Level != sentry.LevelError || e.Tags["request_id"] != "req-1" ||
		e.Contexts["log"]["error"] != "Unknown column" || strings.Join(e.Fingerprint, ",") != "product page failed" {
		t.Errorf("event %q %s %v %v %v", e.Message, e.Level, e.Tags, e.Contexts["log"], e.Fingerprint)
	}
	if e.Request == nil || e.Request.URL != "http://seller.gumroad.com/l/abc" || e.Request.QueryString != "wanted=true" ||
		strings.Contains(e.Request.Cookies+e.Request.Headers["Cookie"], "secret") {
		t.Errorf("request %+v", e.Request)
	}
	frames := e.Threads[0].Stacktrace.Frames
	if last := frames[len(frames)-1]; last.Function != "TestErrorLinesAreReportedWithTheirRequestAndCallSite" || !last.InApp {
		t.Errorf("the stack ends at %s.%s (in app: %v)", last.Module, last.Function, last.InApp)
	}
	var line map[string]any
	if err := json.Unmarshal(logs.Bytes(), &line); err != nil || line["uuid"] != "req-1" || line["error"] != "Unknown column" || line["request"] != nil {
		t.Errorf("log line %s", logs.String())
	}
}

// LogOnly lines copy a Rails.logger.error line, which Rails doesn't report either.
func TestOnlyUnmarkedErrorLinesAreReported(t *testing.T) {
	logger, logs, sent := newTestLogger(t)
	logger.Info("handing request to Rails", "reason", "landing route")
	logger.Warn("avatar variant push failed")
	logger.Error("[License Verification Error] product_id missing, responding with HTTP 500 for product: 1", errorreport.LogOnly)
	if events := sent.Events(); len(events) != 0 {
		t.Errorf("reported %q", events[0].Message)
	}
	if !strings.Contains(logs.String(), "[License Verification Error]") || strings.Contains(logs.String(), "log_only") {
		t.Errorf("logs %s", logs.String())
	}
}

func TestNothingIsReportedBeforeInit(t *testing.T) {
	var logs bytes.Buffer
	logger := slog.New(errorreport.NewHandler(slog.NewJSONHandler(&logs, nil)))
	logger.Error("product page failed", "error", "boom")
	if !strings.Contains(logs.String(), "product page failed") {
		t.Errorf("logs %s", logs.String())
	}
}

// Rails' enabled_environments.
func TestInitSkipsOtherEnvironmentsAndAMissingDSN(t *testing.T) {
	for _, tc := range [][2]string{{"https://public@example.com/1", "development"}, {"https://public@example.com/1", "test"}, {"", "production"}} {
		reporting, err := errorreport.Init(tc[0], tc[1], "abc123")
		if err != nil {
			t.Fatal(err)
		}
		if reporting || sentry.CurrentHub().Client().IsEnabled() {
			t.Errorf("%q in %s started a client", tc[0], tc[1])
		}
	}
}
