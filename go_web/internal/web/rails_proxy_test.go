package web

import (
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// testProxy reads upstreams from a file the test rewrites, on a clock the test moves.
type testProxy struct {
	*RailsProxy
	t     *testing.T
	file  string
	clock time.Time
	mtime time.Time
}

func newTestProxy(t *testing.T, upstreams ...string) *testProxy {
	tp := &testProxy{t: t, file: filepath.Join(t.TempDir(), "upstreams"), clock: time.Unix(1_800_000_000, 0), mtime: time.Unix(1_700_000_000, 0)}
	tp.write(upstreams...)
	tp.RailsProxy = NewRailsProxy(tp.file)
	tp.now = func() time.Time { return tp.clock }
	tp.pick = func(int) int { return 0 }
	return tp
}

// write replaces the file with a later mtime, which is how the proxy notices.
func (tp *testProxy) write(upstreams ...string) {
	tp.t.Helper()
	if err := os.WriteFile(tp.file, []byte(strings.Join(upstreams, "\n")+"\n"), 0o600); err != nil {
		tp.t.Fatal(err)
	}
	tp.mtime = tp.mtime.Add(time.Second)
	if err := os.Chtimes(tp.file, tp.mtime, tp.mtime); err != nil {
		tp.t.Fatal(err)
	}
}

func (tp *testProxy) forward(r *http.Request) *httptest.ResponseRecorder {
	w := httptest.NewRecorder()
	tp.Forward(w, r, "test")
	return w
}

func addr(s *httptest.Server) string { return strings.TrimPrefix(s.URL, "http://") }

func deadAddr(t *testing.T) string {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	a := l.Addr().String()
	l.Close()
	return a
}

func TestRailsProxyForwardsTheRequestAsItArrived(t *testing.T) {
	var got *http.Request
	rails := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = r
		w.Header().Set("X-Revision", "rails")
		w.Header().Set("Content-Encoding", "gzip")
		w.Header().Add("Set-Cookie", "a=1")
		w.WriteHeader(http.StatusFound)
		io.WriteString(w, "from rails")
	}))
	defer rails.Close()
	tp := newTestProxy(t, addr(rails))

	r := httptest.NewRequest("GET", "/d/abc?z=1;y=2&ref=50%off", nil)
	r.Host = "seller.gumroad.com"
	r.Header.Set("X-Forwarded-For", "203.0.113.9, 10.1.0.5")
	r.Header.Set("X-Forwarded-Proto", "https")
	r.Header.Set("X-Forwarded-Host", "seller.gumroad.com")
	r.Header.Set("Cookie", "_gumroad_app_session=s")
	r.Header.Set("Accept-Encoding", "gzip")
	r.Header.Set("X-Inertia", "true")
	w := httptest.NewRecorder()
	w.Header().Set("X-Revision", "go_web")
	w.Header().Set("X-Request-Id", "go-web-request-id")
	tp.Forward(w, r, "test")

	if got == nil {
		t.Fatal("Rails never saw the request")
	}
	for name, want := range map[string]string{
		"X-Forwarded-For": "203.0.113.9, 10.1.0.5", "X-Forwarded-Proto": "https", "X-Forwarded-Host": "seller.gumroad.com",
		"Cookie": "_gumroad_app_session=s", "X-Inertia": "true", "Accept-Encoding": "gzip", "X-Request-Id": "go-web-request-id",
	} {
		if got.Header.Get(name) != want {
			t.Errorf("Rails got %s %q, want %q", name, got.Header.Get(name), want)
		}
	}
	if got.Host != "seller.gumroad.com" || got.URL.RequestURI() != "/d/abc?z=1;y=2&ref=50%off" {
		t.Errorf("Rails got %s %s", got.Host, got.URL.RequestURI())
	}
	if w.Code != http.StatusFound || w.Body.String() != "from rails" || len(w.Header().Values("X-Revision")) != 1 ||
		w.Header().Get("X-Revision") != "rails" || w.Header().Get("X-Request-Id") != "" || w.Header().Get("Set-Cookie") != "a=1" ||
		w.Header().Get("Content-Encoding") != "gzip" {
		t.Errorf("client got %d %q %v", w.Code, w.Body.String(), w.Header())
	}
}

func TestRailsProxyRetriesAGetOrHeadOnAHostThatRefuses(t *testing.T) {
	var methods []string
	rails := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		methods = append(methods, r.Method)
		io.WriteString(w, "ok")
	}))
	defer rails.Close()
	tp := newTestProxy(t, deadAddr(t), addr(rails))
	for _, method := range []string{"GET", "HEAD"} {
		if w := tp.forward(httptest.NewRequest(method, "/x", nil)); w.Code != 200 {
			t.Errorf("%s: %d", method, w.Code)
		}
	}
	if w := tp.forward(httptest.NewRequest("POST", "/x", strings.NewReader("a=1"))); w.Code != http.StatusInternalServerError {
		t.Errorf("a POST must not be sent twice: %d", w.Code)
	}
	if w := tp.forward(httptest.NewRequest("GET", "/x", strings.NewReader("a=1"))); w.Code != http.StatusInternalServerError {
		t.Errorf("a GET with a body must not be retried with the closed body: %d", w.Code)
	}
	if strings.Join(methods, ",") != "GET,HEAD" {
		t.Errorf("Rails saw %v", methods)
	}
}

func TestRailsProxyRereadsTheListWhenItChanges(t *testing.T) {
	first := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "first") }))
	defer first.Close()
	second := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "second") }))
	defer second.Close()
	tp := newTestProxy(t, addr(first))
	body := func() string { return tp.forward(httptest.NewRequest("GET", "/x", nil)).Body.String() }
	if got := body(); got != "first" {
		t.Fatal(got)
	}
	tp.write(addr(second))
	if got := body(); got != "first" {
		t.Errorf("the list is rechecked every %s, not on every request: %s", railsUpstreamsTTL, got)
	}
	tp.clock = tp.clock.Add(railsUpstreamsTTL)
	if got := body(); got != "second" {
		t.Errorf("after a change: %s", got)
	}
	os.Remove(tp.file)
	tp.clock = tp.clock.Add(railsUpstreamsTTL)
	if got := body(); got != "second" {
		t.Errorf("a failed read keeps the last good list: %s", got)
	}
}

func TestRailsProxyLoadsTheListBeforeTheFirstRequest(t *testing.T) {
	rails := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "ok") }))
	defer rails.Close()
	tp := newTestProxy(t, addr(rails))
	if hosts := tp.snapshot.Load().hosts; len(hosts) != 1 {
		t.Fatalf("hosts at start: %v", hosts)
	}
	// While another request holds the refresh, a request with no list waits for one.
	tp.snapshot.Store(&upstreamList{})
	tp.refreshing.Lock()
	done := make(chan int)
	go func() { done <- tp.forward(httptest.NewRequest("GET", "/x", nil)).Code }()
	select {
	case code := <-done:
		t.Fatalf("answered %d without a list", code)
	case <-time.After(50 * time.Millisecond):
	}
	tp.refreshing.Unlock()
	if code := <-done; code != 200 {
		t.Errorf("after the refresh: %d", code)
	}
}

func TestRailsProxyWithoutUpstreamsFails(t *testing.T) {
	dead := deadAddr(t)
	for name, upstreams := range map[string][]string{"no live host": {dead}, "unparseable lines": {"not an address", ""}} {
		if w := newTestProxy(t, upstreams...).forward(httptest.NewRequest("GET", "/x", nil)); w.Code != http.StatusInternalServerError {
			t.Errorf("%s: %d", name, w.Code)
		}
	}
	w := httptest.NewRecorder()
	NewRailsProxy(filepath.Join(t.TempDir(), "missing")).Forward(w, httptest.NewRequest("GET", "/x", nil), "test")
	if w.Code != http.StatusInternalServerError {
		t.Errorf("no file: %d", w.Code)
	}
}

func TestRailsProxyRefusesAResponseAlreadyStarted(t *testing.T) {
	rails := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "rails") }))
	defer rails.Close()
	tp := newTestProxy(t, addr(rails))
	rec := &statusRecorder{ResponseWriter: httptest.NewRecorder()}
	rec.WriteHeader(http.StatusTeapot)
	tp.Forward(rec, httptest.NewRequest("GET", "/x", nil), "test")
	if body := rec.ResponseWriter.(*httptest.ResponseRecorder).Body.String(); body != "" {
		t.Errorf("wrote %q after the response started", body)
	}
}
