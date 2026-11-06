// Package products serves the product page, GET /l/:id (LinksController#show), for a
// signed-out visitor on a seller's subdomain: Rails' filters, then Products/Show. Every
// request whose Rails path this port leaves out goes to Rails before anything is written.
package products

import (
	"context"
	"database/sql"
	"errors"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/inertia"
	"github.com/antiwork/gumroad/go_web/internal/obfuscate"
	"github.com/antiwork/gumroad/go_web/internal/pages"
	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/session"
	"github.com/antiwork/gumroad/go_web/internal/web"
)

// readTimeout bounds the page's reads; Puma has no per-request deadline, so a page that
// runs out goes to Rails.
const readTimeout = 5 * time.Second

// Config is what the action reads besides the request.
type Config struct {
	Env      *web.Environment
	DB       *sql.DB
	Stack    *rails.Stack
	Store    *session.Store
	Resolver *session.Resolver
	IDs      *obfuscate.IDs
	Proxy    *web.RailsProxy
	Meta     inertia.DefaultMeta
	Now      func() time.Time
	// Page is what rendering reads; nil leaves every page to Rails.
	Page *PageConfig
	// DryRunKey signs dry-run requests, and DryRunOnce remembers the ones used.
	DryRunKey  []byte
	DryRunOnce pages.DryRunStore
}

func Register(app *web.App, c *Config) {
	h := &handler{c: c, ctl: &pages.Controller{
		Env: c.Env, Stack: c.Stack, Store: c.Store, Resolver: c.Resolver, Proxy: c.Proxy,
		Redirects: app.Redirects(), Meta: c.Meta, Now: c.Now, DryRunKey: c.DryRunKey, DryRunOnce: c.DryRunOnce,
	}}
	app.HandlePage("GET /l/{id}", "LinksController#show", h)
	// /l/:id/:code (an offer code) and a trailing slash.
	app.HandlePage("GET /l/{id}/{rest...}", "LinksController#show", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h.ctl.Serve(w, r, "product page", func(*http.Request) (*pages.Visit, error) { return nil, pages.Fallback("offer code path") })
	}))
}

type handler struct {
	c   *Config
	ctl *pages.Controller
}

// page is the controller instance for one request.
type page struct {
	*pages.Visit
	// seller is the subdomain's seller, user_by_domain.
	seller *user
	// cacheWrites are the Rails.cache writes the render makes, made once it renders here.
	cacheWrites        []pendingWrite
	rates              map[string]rateRead
	hasCollaborator    bool
	hasInstallmentPlan bool
	hasBundleProducts  bool
	// settleable is buyer_currency_settleable? for the page's seller and buyer currency.
	settleable  *bool
	productsKey string
	// warmReputation is snapshot_reputation_aggregate's perform_async, made once the page is
	// certain to render here.
	warmReputation bool
}

type fallback = pages.Fallback

func (h *handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), readTimeout)
	defer cancel()
	h.ctl.Serve(w, r, "product page", func(r *http.Request) (*pages.Visit, error) {
		p, err := h.prepare(ctx, r)
		if err == nil {
			err = h.serve(w, p)
		}
		// Only reads take ctx, and they all finish before anything is written.
		if errors.Is(err, context.DeadlineExceeded) {
			err = fallback("read timeout")
		}
		if p == nil {
			return nil, err
		}
		return p.Visit, err
	})
}

// subdomainHost is a seller subdomain as Subdomain.subdomain_request? matches it, with the
// dots it leaves unescaped taken literally; any other host goes to Rails.
var subdomainHost = regexp.MustCompile(`\A([a-z0-9-]+)\.gumroad\.com\z`)

// analyticsHost is routes.rb's unanchored host constraint for THIRD_PARTY_ANALYTICS_DOMAIN,
// which a subdomain like gumroad-analytics-com.gumroad.com also meets, so Rails 404s it.
var analyticsHost = regexp.MustCompile(`gumroad-analytics.com`)

// permalinkParam is what a custom or unique permalink can be. Anything else needs Rails'
// path decoding or would carry a format.
var permalinkParam = regexp.MustCompile(`\A[A-Za-z0-9_-]+\z`)

// prepare parses the request and decides whether this port serves it. Nothing it does is
// visible outside the process, so any fallback it returns is safe.
func (h *handler) prepare(ctx context.Context, r *http.Request) (*page, error) {
	if h.c.Page == nil {
		return nil, fallback("pages off")
	}
	if reason := declined(r, h.c.Env); reason != "" {
		return nil, fallback(reason)
	}
	v, err := h.ctl.Prepare(ctx, r, [][2]string{{"format", "html"}, {"controller", "links"}, {"action", "show"}, {"id", r.PathValue("id")}},
		func(req *rails.Request) error {
			if reason := declinedParams(req); reason != "" {
				return fallback(reason)
			}
			return nil
		})
	if err != nil {
		return nil, err
	}
	if v.Auth.LoggedInUser() != nil {
		return nil, fallback("signed in")
	}
	return &page{Visit: v}, nil
}

// declined is everything decided by the request line and headers alone.
func declined(r *http.Request, env *web.Environment) string {
	host := web.Host(r)
	m := subdomainHost.FindStringSubmatch(host)
	switch {
	case r.Method != http.MethodGet:
		return "method"
	case m == nil || env.RootDomain != "gumroad.com":
		// The app domain redirects here, and custom domains route by their own rules.
		return "host"
	case m[1] == "www" || m[1] == "app" || env.IsGumroadHost(host) || analyticsHost.MatchString(host):
		return "host"
	case !permalinkParam.MatchString(r.PathValue("id")):
		return "permalink"
	case !rails.SecureCookies(env.Protocol, r):
		return "not ssl"
	case web.HostWithPort(r) != host || web.ForwardedPort(r) != "" && web.ForwardedPort(r) != "443":
		// Rails' URLs here would carry the port.
		return "port"
	case r.ContentLength != 0 || len(r.TransferEncoding) > 0:
		// Parsing reads the body, which a fallback after it could no longer send.
		return "request body"
	}
	return pages.DeclinedHeaders(r)
}

// rendererParams are the params whose effect on the page this port leaves to Rails.
var rendererParams = []string{
	// The action and its presenter.
	"wanted", "layout", "embed", "overlay", "recommended_by", "offer_code", "code", "quantity", "purchase_id",
	"purchase_email_digest", "currency", "option", "variant", "price", "recurrence", "rent", "native", "debug",
	"query", "autocomplete",
	// set_affiliate_cookie and the sections' search filters.
	"affiliate_id", "a", "tags", "filetypes", "min_price", "max_price", "rating", "sort", "from", "size",
	// MobileAppWebView and as_embed.
	"display", "as_embed",
}

// declinedParams is a param this port leaves to Rails.
func declinedParams(req *rails.Request) string {
	for _, name := range rendererParams {
		if _, ok := req.Params.Get(name); ok {
			return "param " + name
		}
	}
	// track_utm_link_visit records a visit when all three are present.
	if rails.Present(req.Param("utm_source")) && rails.Present(req.Param("utm_medium")) && rails.Present(req.Param("utm_campaign")) {
		return "utm link"
	}
	for _, key := range req.Params.Keys() {
		if strings.HasPrefix(key, "monthly") || strings.HasPrefix(key, "quarterly") || strings.HasPrefix(key, "biannually") ||
			strings.HasPrefix(key, "yearly") || strings.HasPrefix(key, "every_two_years") {
			// BasePrice::Recurrence params that ?wanted=true reads.
			return "param " + key
		}
	}
	return ""
}
