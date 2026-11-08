package web

import (
	"bytes"
	"context"
	"errors"
	"io"
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
	// railsRevisionTimeout bounds Revision's round of /healthcheck requests.
	railsRevisionTimeout = 2 * time.Second
	// Fallbacks are a minority of requests, but bursts would otherwise reconnect every time.
	railsIdleConnsPerHost = 32
	// A host that refused, or whose nginx couldn't reach Puma, is likely stopping; Consul's
	// check takes up to its 10s interval, plus the template render, to drop it.
	railsUpstreamDownFor = 30 * time.Second
	// nginx's proxy_next_upstream_timeout: a first attempt can spend it before its 504.
	railsNginxRetryBudget = 10 * time.Second
	maxReplayBody         = 64 << 10
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

	downMu    sync.Mutex
	downUntil map[string]time.Time

	// probe asks the hosts for their revision.
	probe *http.Client
}

type upstreamList struct {
	checkedAt time.Time
	modTime   time.Time
	hosts     []string
}

func NewRailsProxy(upstreamsFile string) *RailsProxy {
	p := &RailsProxy{path: upstreamsFile, now: time.Now, pick: rand.IntN, probe: &http.Client{Timeout: railsRevisionTimeout}}
	p.reload(&upstreamList{})
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
	keep := r.ContentLength > 0 && r.ContentLength <= maxReplayBody
	if id != "" || keep {
		r = r.Clone(r.Context())
	}
	if id != "" {
		r.Header.Set("X-Request-Id", id)
	}
	// Kept so a request that never reached Puma can go to another host.
	if keep {
		body := make([]byte, r.ContentLength)
		if _, err := io.ReadFull(r.Body, body); err != nil {
			p.proxy.ErrorHandler(w, r, err)
			return
		}
		r.Body = io.NopCloser(bytes.NewReader(body))
		r.GetBody = func() (io.ReadCloser, error) { return io.NopCloser(bytes.NewReader(body)), nil }
	}
	// The server's write timeout would end the response before Rails is done.
	http.NewResponseController(w).SetWriteDeadline(p.now().Add(railsProxyTimeout + railsDialTimeout*2 + railsNginxRetryBudget))
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

// upstream picks a Rails host other than skip, preferring hosts not marked down. One caller
// rereads a stale list while the rest keep the last one.
func (p *RailsProxy) upstream(skip string) (string, error) {
	list := p.snapshot.Load()
	if len(list.hosts) == 0 {
		// Nothing to keep using: wait for whoever is reading the file, then read it again.
		p.refreshing.Lock()
		list = p.reload(p.snapshot.Load())
		p.refreshing.Unlock()
	} else if p.now().Sub(list.checkedAt) >= railsUpstreamsTTL && p.refreshing.TryLock() {
		list = p.reload(list)
		p.refreshing.Unlock()
	}
	hosts := list.hosts
	if down := p.downHosts(); skip != "" || len(down) > 0 {
		up, rest := make([]string, 0, len(list.hosts)), make([]string, 0, len(list.hosts))
		for _, h := range list.hosts {
			if h == skip {
				continue
			}
			rest = append(rest, h)
			if !down[h] {
				up = append(up, h)
			}
		}
		// Every host down is likelier a blip on this side than all of Rails stopping.
		hosts = up
		if len(up) == 0 {
			hosts = rest
		}
	}
	if len(hosts) == 0 {
		return "", errNoUpstream
	}
	return hosts[p.pick(len(hosts))], nil
}

func (p *RailsProxy) markDown(host string) {
	p.downMu.Lock()
	defer p.downMu.Unlock()
	if p.downUntil == nil {
		p.downUntil = map[string]time.Time{}
	}
	p.downUntil[host] = p.now().Add(railsUpstreamDownFor)
}

// downHosts drops expired marks and returns the hosts still down.
func (p *RailsProxy) downHosts() map[string]bool {
	p.downMu.Lock()
	defer p.downMu.Unlock()
	if len(p.downUntil) == 0 {
		return nil
	}
	now, down := p.now(), map[string]bool{}
	for h, until := range p.downUntil {
		if now.Before(until) {
			down[h] = true
		} else {
			delete(p.downUntil, h)
		}
	}
	return down
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

// Revision is the REVISION most Rails hosts report: debug_headers' X-Revision on their
// /healthcheck, which their nginx serves as Consul's check does. "" is no answer or a tie, as
// both colors give while a deploy switches them.
func (p *RailsProxy) Revision(ctx context.Context) string {
	p.refreshing.Lock()
	list := p.reload(p.snapshot.Load())
	p.refreshing.Unlock()
	ctx, cancel := context.WithTimeout(ctx, railsRevisionTimeout)
	defer cancel()
	revisions := make(chan string, len(list.hosts))
	for _, host := range list.hosts {
		go func() {
			var revision string
			req, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://"+host+"/healthcheck", nil)
			if err == nil {
				if res, err := p.probe.Do(req); err == nil {
					io.Copy(io.Discard, io.LimitReader(res.Body, 4<<10))
					res.Body.Close()
					if res.StatusCode == http.StatusOK {
						revision = res.Header.Get("X-Revision")
					}
				}
			}
			revisions <- revision
		}()
	}
	counts := map[string]int{}
	for range list.hosts {
		if r := <-revisions; r != "" {
			counts[r]++
		}
	}
	best, tied := "", false
	for r, n := range counts {
		switch {
		case n > counts[best]:
			best, tied = r, false
		case n == counts[best]:
			tied = true
		}
	}
	if tied {
		return ""
	}
	return best
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

// retryTransport sends a request to a second Rails host when nothing reached Puma on the
// first: the dial was refused, or its nginx answered 502 or 504 having sent Puma nothing.
// Nothing ran, so any method whose body Forward kept can retry.
type retryTransport struct {
	next  http.RoundTripper
	proxy *RailsProxy
}

func (t *retryTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	first, err := t.proxy.upstream("")
	if err != nil {
		return nil, err
	}
	res, err := t.send(req, first, nil)
	if !replayable(req) || !neverReachedPuma(res, err) {
		return res, err
	}
	t.proxy.markDown(first)
	second, uerr := t.proxy.upstream(first)
	if uerr != nil {
		return res, err
	}
	if res != nil {
		// Unread: a host stalling mid-body would hold up the retry, and it's marked down anyway.
		res.Body.Close()
	}
	var body io.ReadCloser
	if req.GetBody != nil {
		if body, err = req.GetBody(); err != nil {
			return nil, err
		}
	}
	res, err = t.send(req, second, body)
	if neverReachedPuma(res, err) {
		t.proxy.markDown(second)
	}
	return res, err
}

// replayable is whether the request can be sent again: no body, or one Forward kept.
func replayable(req *http.Request) bool {
	return req.Body == nil || req.Body == http.NoBody || req.GetBody != nil
}

func neverReachedPuma(res *http.Response, err error) bool {
	if err != nil {
		var dialErr *net.OpError
		return errors.As(err, &dialErr) && dialErr.Op == "dial" && !errors.Is(err, context.Canceled)
	}
	return unsent(res)
}

// unsent is Rails' nginx reporting, in X-Upstream-Bytes-Sent ($upstream_bytes_sent, one
// value per attempt), that no attempt sent Puma a byte.
func unsent(res *http.Response) bool {
	if res.StatusCode != http.StatusBadGateway && res.StatusCode != http.StatusGatewayTimeout {
		return false
	}
	sent := res.Header.Get("X-Upstream-Bytes-Sent")
	if sent == "" {
		return false
	}
	for _, v := range strings.FieldsFunc(sent, func(r rune) bool { return r == ',' || r == ':' || r == ' ' }) {
		if v != "0" {
			return false
		}
	}
	return true
}

// send aims the outbound request at upstream, with body in place of a spent one. ReverseProxy
// has already cloned it, so a shallow copy is enough.
func (t *retryTransport) send(req *http.Request, upstream string, body io.ReadCloser) (*http.Response, error) {
	out := *req
	u := *req.URL
	u.Host = upstream
	out.URL = &u
	if body != nil {
		out.Body = body
	}
	return t.next.RoundTrip(&out)
}

// bufferPool reuses ReverseProxy's 32 KB copy buffers.
type bufferPool struct{}

var copyBuffers = sync.Pool{New: func() any { b := make([]byte, 32<<10); return &b }}

func (bufferPool) Get() []byte  { return *copyBuffers.Get().(*[]byte) }
func (bufferPool) Put(b []byte) { copyBuffers.Put(&b) }
