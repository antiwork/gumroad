package web

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"regexp"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/redis/go-redis/v9"
)

// SubdomainRedirectorService's Redis::Namespace key.
const subdomainRedirectsKey = "subdomain_redirect_namespace:subdomain_redirects_config"

// Rails keeps the parsed table in Rails.cache until an admin edit clears it; a short
// refresh here bounds how long an edit takes to reach this fleet.
const (
	subdomainRedirectsRefresh = 30 * time.Second
	subdomainRedirectsTimeout = 500 * time.Millisecond
)

var (
	absoluteLocation  = regexp.MustCompile(`(?i)\A([a-z][a-z\d\-+.]*:|//)`)
	unsafeLocation    = regexp.MustCompile(`[\x00-\x08\x0A-\x1F]`)
	locationStripper  = strings.NewReplacer("\x00", "", "\r", "", "\n", "")
	errUnsafeRedirect = errors.New("redirect location Rails refuses")
)

// SubdomainRedirects is ApplicationController#redirect_to_custom_subdomain, which runs
// before every Rails action the routes here replace.
type SubdomainRedirects struct {
	client    redis.Cmdable
	protected map[string]bool
	logger    *slog.Logger

	snapshot   atomic.Pointer[redirectTable]
	refreshing sync.Mutex
}

type redirectTable struct {
	entries  map[string]string
	loadedAt time.Time
}

func NewSubdomainRedirects(client redis.Cmdable, env *Environment, logger *slog.Logger) *SubdomainRedirects {
	protected := map[string]bool{}
	for _, host := range slices.Concat(env.ValidAPIRequestHosts, env.ValidRequestHosts) {
		protected[host] = true
	}
	s := &SubdomainRedirects{client: client, protected: protected, logger: logger}
	s.snapshot.Store(&redirectTable{entries: map[string]string{}})
	s.refresh()
	return s
}

// Location returns where the request must be redirected, or "" to serve it. The error
// marks the locations Rails' redirect_to raises on, which it answers with a 500.
func (s *SubdomainRedirects) Location(r *http.Request) (string, error) {
	table := s.current()
	if len(table) == 0 {
		return "", nil
	}
	fullpath := Fullpath(r)
	key := Host(r)
	if fullpath != "/" {
		key += fullpath
	}
	location := table[key]
	if location == "" {
		return "", nil
	}
	if !absoluteLocation.MatchString(location) {
		// load_defaults 8.1 raises on path-relative redirects.
		if !strings.HasPrefix(location, "/") && !strings.HasPrefix(location, "?") {
			return "", errUnsafeRedirect
		}
		location = Protocol(r) + HostWithPort(r) + location
	}
	location = locationStripper.Replace(location)
	if unsafeLocation.MatchString(location) {
		return "", errUnsafeRedirect
	}
	return location, nil
}

// current never blocks: one caller refreshes a stale table while the rest keep using it.
func (s *SubdomainRedirects) current() map[string]string {
	table := s.snapshot.Load()
	if time.Since(table.loadedAt) >= subdomainRedirectsRefresh && s.refreshing.TryLock() {
		defer s.refreshing.Unlock()
		s.refresh()
		table = s.snapshot.Load()
	}
	return table.entries
}

func (s *SubdomainRedirects) refresh() {
	ctx, cancel := context.WithTimeout(context.Background(), subdomainRedirectsTimeout)
	defer cancel()
	entries := s.snapshot.Load().entries
	config, err := s.client.Get(ctx, subdomainRedirectsKey).Result()
	switch {
	case errors.Is(err, redis.Nil):
		entries = map[string]string{}
	case err != nil:
		// Rails degrades a failed read to "no redirects"; keep the last table instead.
		s.logger.Warn("Could not read subdomain redirects", "error", err.Error())
	default:
		entries = parseSubdomainRedirects(config, s.protected)
	}
	s.snapshot.Store(&redirectTable{entries: entries, loadedAt: time.Now()})
}

func parseSubdomainRedirects(config string, protected map[string]bool) map[string]string {
	table := map[string]string{}
	for line := range strings.SplitSeq(config, "\n") {
		host, location, _ := strings.Cut(line, "=")
		host, location = rubyStrip(host), rubyStrip(location)
		if host == "" || location == "" || protected[host] {
			continue
		}
		table[strings.ToLower(host)] = location
	}
	return table
}

func rubyStrip(s string) string {
	return strings.Trim(s, " \t\n\v\f\r\x00")
}
