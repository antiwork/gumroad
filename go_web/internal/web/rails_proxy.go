package web

import (
	"context"
	"errors"
	"math/rand/v2"
	"net"
	"net/http"
	"net/http/httputil"
	"os"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const (
	// Rails' nginx gives Puma 120s; a fallback gets most of what a Rails request would.
	railsProxyTimeout = 100 * time.Second
	// A terminated host never refuses, so the dial has to give up quickly for the retry
	// to run, as the Rails nginx's own upstream connect does.
	railsDialTimeout  = 2 * time.Second
	railsUpstreamsTTL = 5 * time.Second
	// Fallbacks are a minority of requests, but bursts would otherwise reconnect every time.
	railsIdleConnsPerHost = 32
)

// RailsProxy hands a request to a Rails web host unchanged, for the cases a ported action
// leaves to Rails because porting them exactly isn't worth it.
//
// The upstreams are host:port lines Nomad renders from Consul's passing "web" instances,
// the Rails nginx in front of Puma. That nginx appends this host to X-Forwarded-For, a
// private address Rails' remote_ip skips, and passes every other header through, so Rails
// sees the request as if the load balancer had sent it. Only the file decides where a
// request goes.
type RailsProxy struct {
	path  string
	now   func() time.Time
	pick  func(n int) int
	proxy *httputil.ReverseProxy

	snapshot   atomic.Pointer[upstreamList]
	refreshing sync.Mutex
}

type upstreamList struct {
	checkedAt time.Time
	modTime   time.Time
	hosts     []string
}

func NewRailsProxy(upstreamsFile string) *RailsProxy {
	p := &RailsProxy{path: upstreamsFile, now: time.Now, pick: rand.IntN}
	p.snapshot.Store(&upstreamList{})
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = nil
	transport.DialContext = (&net.Dialer{Timeout: railsDialTimeout, KeepAlive: 30 * time.Second}).DialContext
	transport.ResponseHeaderTimeout = railsProxyTimeout
	transport.MaxIdleConns = 0
	transport.MaxIdleConnsPerHost = railsIdleConnsPerHost
	// Rails' response goes back as it came, compressed or not.
	transport.DisableCompression = true
	p.proxy = &httputil.ReverseProxy{
		Rewrite:    p.rewrite,
		Transport:  &retryTransport{next: transport, proxy: p},
		BufferPool: bufferPool{},
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			if r.Context().Err() != nil {
				Logger(r).Info("client left during Rails fallback", "error", err.Error())
				return
			}
			Logger(r).Error("Rails fallback failed", "error", err.Error())
			InternalServerError(w)
		},
	}
	return p
}

// Forward answers r from Rails. A handler calls it before it has written anything or read
// the body, and before it has done anything a client or the database could see. The
// headers App.Handle set are Rails' to send, except the request ID, which Rails then logs.
func (p *RailsProxy) Forward(w http.ResponseWriter, r *http.Request, reason string) {
	if rec, ok := w.(*statusRecorder); ok && rec.status != 0 {
		Logger(r).Error("Rails fallback after the response started", "reason", reason)
		return
	}
	id := w.Header().Get("X-Request-Id")
	for k := range w.Header() {
		delete(w.Header(), k)
	}
	if id != "" {
		r = r.Clone(r.Context())
		r.Header.Set("X-Request-Id", id)
	}
	// The server's write timeout would end the response before Rails is done.
	http.NewResponseController(w).SetWriteDeadline(p.now().Add(railsProxyTimeout + railsDialTimeout*2))
	Logger(r).Info("handing request to Rails", "reason", reason)
	p.proxy.ServeHTTP(w, r)
}

// rewrite keeps the request as it arrived. Rewrite drops the X-Forwarded headers, which
// Rails reads, and would re-encode a query Go can't parse.
func (p *RailsProxy) rewrite(pr *httputil.ProxyRequest) {
	for _, h := range []string{"X-Forwarded-For", "X-Forwarded-Host", "X-Forwarded-Proto"} {
		if v, ok := pr.In.Header[h]; ok {
			pr.Out.Header[h] = v
		}
	}
	pr.Out.URL.Scheme = "http"
	pr.Out.URL.RawQuery = pr.In.URL.RawQuery
}

var errNoUpstream = errors.New("no Rails upstream")

// upstream picks a Rails host other than skip. One caller rereads a stale list while the
// rest keep the last one.
func (p *RailsProxy) upstream(skip string) (string, error) {
	list := p.snapshot.Load()
	if p.now().Sub(list.checkedAt) >= railsUpstreamsTTL && p.refreshing.TryLock() {
		list = p.reload(list)
		p.refreshing.Unlock()
	}
	skipAt, n := -1, len(list.hosts)
	if skip != "" {
		if skipAt = slices.Index(list.hosts, skip); skipAt >= 0 {
			n--
		}
	}
	if n == 0 {
		return "", errNoUpstream
	}
	i := p.pick(n)
	if skipAt >= 0 && i >= skipAt {
		i++
	}
	return list.hosts[i], nil
}

// reload rereads the file when it changed; a failed read keeps the last good list.
func (p *RailsProxy) reload(old *upstreamList) *upstreamList {
	next := *old
	next.checkedAt = p.now()
	if info, err := os.Stat(p.path); err == nil && !info.ModTime().Equal(old.modTime) {
		if data, err := os.ReadFile(p.path); err == nil {
			next.modTime, next.hosts = info.ModTime(), parseUpstreams(string(data))
		}
	}
	p.snapshot.Store(&next)
	return &next
}

func parseUpstreams(data string) []string {
	var hosts []string
	for line := range strings.SplitSeq(data, "\n") {
		line = strings.TrimSpace(line)
		if _, port, err := net.SplitHostPort(line); err == nil && port != "" && !slices.Contains(hosts, line) {
			hosts = append(hosts, line)
		}
	}
	return hosts
}

// retryTransport sends a request to a second Rails host when the first refused the
// connection: nothing reached Rails, so nothing ran twice. Only a bodiless GET or HEAD
// retries, since a failed dial closes the request body.
type retryTransport struct {
	next  http.RoundTripper
	proxy *RailsProxy
}

func (t *retryTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	first, err := t.proxy.upstream("")
	if err != nil {
		return nil, err
	}
	res, err := t.send(req, first)
	if err == nil || !retryable(req, err) {
		return res, err
	}
	second, uerr := t.proxy.upstream(first)
	if uerr != nil {
		return nil, err
	}
	return t.send(req, second)
}

func retryable(req *http.Request, err error) bool {
	var dialErr *net.OpError
	return (req.Method == http.MethodGet || req.Method == http.MethodHead) &&
		errors.As(err, &dialErr) && dialErr.Op == "dial" && !errors.Is(err, context.Canceled)
}

// send aims the outbound request at upstream. ReverseProxy has already cloned it, so a
// copy with its own URL is enough.
func (t *retryTransport) send(req *http.Request, upstream string) (*http.Response, error) {
	out := *req
	u := *req.URL
	u.Host = upstream
	out.URL = &u
	return t.next.RoundTrip(&out)
}

// bufferPool reuses ReverseProxy's 32 KB copy buffers.
type bufferPool struct{}

var copyBuffers = sync.Pool{New: func() any { b := make([]byte, 32<<10); return &b }}

func (bufferPool) Get() []byte  { return *copyBuffers.Get().(*[]byte) }
func (bufferPool) Put(b []byte) { copyBuffers.Put(&b) }
