package web

import (
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
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

// A refused dial sent nothing, so any request whose body was kept goes to the next host.
func TestRailsProxyRetriesOnAHostThatRefuses(t *testing.T) {
	var seen []string
	rails := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		seen = append(seen, r.Method+" "+string(body))
		io.WriteString(w, "ok")
	}))
	defer rails.Close()
	dead := deadAddr(t)
	for _, method := range []string{"GET", "HEAD", "POST"} {
		tp := newTestProxy(t, dead, addr(rails))
		var body io.Reader
		if method == "POST" {
			body = strings.NewReader("a=1")
		}
		if w := tp.forward(httptest.NewRequest(method, "/x", body)); w.Code != 200 {
			t.Errorf("%s: %d", method, w.Code)
		}
	}
	if strings.Join(seen, ",") != "GET ,HEAD ,POST a=1" {
		t.Errorf("Rails saw %q", seen)
	}
}

// A body too large to keep can't be sent twice.
func TestRailsProxyDoesNotRetryABodyItDidNotKeep(t *testing.T) {
	rails := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "ok") }))
	defer rails.Close()
	tp := newTestProxy(t, deadAddr(t), addr(rails))
	if w := tp.forward(httptest.NewRequest("POST", "/x", strings.NewReader(strings.Repeat("a", maxReplayBody+1)))); w.Code != http.StatusInternalServerError {
		t.Errorf("%d", w.Code)
	}
}

// stoppingRails is a Rails host whose nginx answers status while Puma is down, with what it
// sent Puma in X-Upstream-Bytes-Sent.
func stoppingRails(t *testing.T, status int, bytesSent string, hits *int) *httptest.Server {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		*hits++
		if bytesSent != "" {
			w.Header().Set("X-Upstream-Bytes-Sent", bytesSent)
		}
		w.WriteHeader(status)
		io.WriteString(w, "500 page")
	}))
	t.Cleanup(s.Close)
	return s
}

func TestRailsProxyRetriesWhenNginxSentPumaNothing(t *testing.T) {
	var bad int
	var seen []string
	good := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		seen = append(seen, string(body))
		io.WriteString(w, "ok")
	}))
	defer good.Close()
	tp := newTestProxy(t, addr(stoppingRails(t, http.StatusBadGateway, "0, 0", &bad)), addr(good))
	for i := range 2 {
		if w := tp.forward(httptest.NewRequest("POST", "/v2/licenses/verify", strings.NewReader("license_key=k"))); w.Code != 200 || w.Body.String() != "ok" {
			t.Fatalf("request %d: %d %q", i, w.Code, w.Body.String())
		}
	}
	// The second request skipped the stopping host.
	if bad != 1 || strings.Join(seen, ",") != "license_key=k,license_key=k" {
		t.Errorf("stopping host hit %d times, Rails saw %q", bad, seen)
	}
	tp.clock = tp.clock.Add(railsUpstreamDownFor)
	tp.forward(httptest.NewRequest("GET", "/x", nil))
	if bad != 2 {
		t.Errorf("the host stayed marked down: %d", bad)
	}
}

func TestRailsProxyPassesOnA502ThatMayHaveReachedPuma(t *testing.T) {
	good := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "ok") }))
	defer good.Close()
	for _, sent := range []string{"163", "0, 163", ""} {
		var hits int
		tp := newTestProxy(t, addr(stoppingRails(t, http.StatusBadGateway, sent, &hits)), addr(good))
		if w := tp.forward(httptest.NewRequest("POST", "/x", strings.NewReader("a=1"))); w.Code != http.StatusBadGateway ||
			w.Body.String() != "500 page" || hits != 1 {
			t.Errorf("bytes sent %q: %d %q, %d hits", sent, w.Code, w.Body.String(), hits)
		}
	}
}

// A stopping host that sends its 502's headers and then stalls can't hold up the retry.
func TestRailsProxyRetriesWithoutWaitingOnAStalledBody(t *testing.T) {
	release := make(chan struct{})
	stalled := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Upstream-Bytes-Sent", "0")
		w.WriteHeader(http.StatusBadGateway)
		w.(http.Flusher).Flush()
		<-release
	}))
	defer stalled.Close()
	defer close(release)
	good := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "ok") }))
	defer good.Close()
	tp := newTestProxy(t, addr(stalled), addr(good))
	done := make(chan *httptest.ResponseRecorder, 1)
	go func() { done <- tp.forward(httptest.NewRequest("GET", "/x", nil)) }()
	select {
	case w := <-done:
		if w.Code != 200 {
			t.Errorf("%d", w.Code)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("the retry waited on the stalled body")
	}
}

// A deploy stops a whole color, so the retry can land on a second stopping host.
func TestRailsProxyKeepsTryingHostsWhileAColorStops(t *testing.T) {
	var a, b int
	good := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "ok") }))
	defer good.Close()
	tp := newTestProxy(t, addr(stoppingRails(t, http.StatusBadGateway, "0", &a)), addr(stoppingRails(t, http.StatusBadGateway, "0", &b)), addr(good))
	if w := tp.forward(httptest.NewRequest("GET", "/l/abc/landing/version", nil)); w.Code != 200 || w.Body.String() != "ok" || a != 1 || b != 1 {
		t.Errorf("%d %q, stopping hosts hit %d and %d times", w.Code, w.Body.String(), a, b)
	}
}

func TestRailsProxyGivesUpAfterItsMaxAttempts(t *testing.T) {
	hits := make([]int, railsMaxAttempts+1)
	var hosts []string
	for i := range hits {
		hosts = append(hosts, addr(stoppingRails(t, http.StatusBadGateway, "0", &hits[i])))
	}
	tp := newTestProxy(t, hosts...)
	if w := tp.forward(httptest.NewRequest("GET", "/x", nil)); w.Code != http.StatusBadGateway || hits[railsMaxAttempts] != 0 {
		t.Errorf("%d, hits %v", w.Code, hits)
	}
}

// A body too large to resend still tells the proxy the host is stopping.
func TestRailsProxyMarksDownAHostItCouldNotRetryPast(t *testing.T) {
	var hits int
	good := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "ok") }))
	defer good.Close()
	tp := newTestProxy(t, addr(stoppingRails(t, http.StatusBadGateway, "0", &hits)), addr(good))
	tp.forward(httptest.NewRequest("POST", "/x", strings.NewReader(strings.Repeat("a", maxReplayBody+1))))
	if w := tp.forward(httptest.NewRequest("GET", "/x", nil)); w.Code != 200 || hits != 1 {
		t.Errorf("%d, stopping host hit %d times", w.Code, hits)
	}
}

// Past nginx's own retry budget a stopping host's answer goes to the client, but the first
// retry still runs after a slow 504.
func TestRailsProxyStopsTryingHostsPastNginxsRetryBudget(t *testing.T) {
	var elapsed atomic.Int64
	slow := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		elapsed.Add(int64(railsNginxRetryBudget))
		w.Header().Set("X-Upstream-Bytes-Sent", "0")
		w.WriteHeader(http.StatusGatewayTimeout)
	}))
	defer slow.Close()
	var b, c int
	tp := newTestProxy(t, addr(slow), addr(stoppingRails(t, http.StatusBadGateway, "0", &b)), addr(stoppingRails(t, http.StatusOK, "", &c)))
	start := tp.clock
	tp.now = func() time.Time { return start.Add(time.Duration(elapsed.Load())) }
	if w := tp.forward(httptest.NewRequest("GET", "/x", nil)); w.Code != http.StatusBadGateway || b != 1 || c != 0 {
		t.Errorf("%d, hosts after the slow one hit %d and %d times", w.Code, b, c)
	}
}

// nginx's 504 when Puma's accept queue is full and the connect times out.
func TestRailsProxyRetriesA504ThatSentPumaNothing(t *testing.T) {
	var hits int
	good := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "ok") }))
	defer good.Close()
	tp := newTestProxy(t, addr(stoppingRails(t, http.StatusGatewayTimeout, "0", &hits)), addr(good))
	if w := tp.forward(httptest.NewRequest("POST", "/x", strings.NewReader("a=1"))); w.Code != 200 || hits != 1 {
		t.Errorf("%d, %d hits", w.Code, hits)
	}
}

// With every host marked down, requests still go to them rather than failing.
func TestRailsProxyUsesDownHostsWhenNoOtherIsLeft(t *testing.T) {
	var a, b int
	tp := newTestProxy(t, addr(stoppingRails(t, http.StatusBadGateway, "0", &a)), addr(stoppingRails(t, http.StatusBadGateway, "0", &b)))
	for range 2 {
		if w := tp.forward(httptest.NewRequest("GET", "/x", nil)); w.Code != http.StatusBadGateway {
			t.Fatalf("%d", w.Code)
		}
	}
	if a+b != 4 {
		t.Errorf("hits %d and %d", a, b)
	}
}

func TestRailsProxyKeepsTheOnly502WithoutAnotherHost(t *testing.T) {
	var hits int
	tp := newTestProxy(t, addr(stoppingRails(t, http.StatusBadGateway, "0", &hits)))
	if w := tp.forward(httptest.NewRequest("GET", "/x", nil)); w.Code != http.StatusBadGateway || w.Body.String() != "500 page" {
		t.Errorf("%d %q", w.Code, w.Body.String())
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

// Revision is the X-Revision most Rails hosts' /healthcheck gives; a tie, as during a deploy's
// switch, or no answer is "".
func TestRailsProxyRevision(t *testing.T) {
	host := func(revision string, status int) string {
		s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path != "/healthcheck" {
				t.Errorf("asked %s", r.URL.Path)
			}
			w.Header().Set("X-Revision", revision)
			w.WriteHeader(status)
		}))
		t.Cleanup(s.Close)
		return addr(s)
	}
	for name, c := range map[string]struct {
		hosts []string
		want  string
	}{
		"the majority":       {[]string{host("new", 200), host("old", 200), host("new", 200)}, "new"},
		"a tie":              {[]string{host("new", 200), host("old", 200)}, ""},
		"a failing host":     {[]string{host("new", 200), host("old", 500), deadAddr(t)}, "new"},
		"no host answers":    {[]string{deadAddr(t)}, ""},
		"a host without one": {[]string{host("", 200)}, ""},
	} {
		t.Run(name, func(t *testing.T) {
			if got := newTestProxy(t, c.hosts...).Revision(t.Context()); got != c.want {
				t.Errorf("%q, want %q", got, c.want)
			}
		})
	}
}
