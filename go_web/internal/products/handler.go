// Package products serves the product page, GET /l/:id (LinksController#show), on a seller's
// subdomain or own custom domain, for a visitor signed out or signed in: Rails' filters, then
// Products/Show. Every request whose Rails path this port leaves out goes to Rails before
// anything is written.
package products

import (
	"cmp"
	"context"
	"database/sql"
	"errors"
	"net/http"
	"regexp"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/antiwork/gumroad/go_web/internal/inertia"
	"github.com/antiwork/gumroad/go_web/internal/obfuscate"
	"github.com/antiwork/gumroad/go_web/internal/pages"
	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/session"
	"github.com/antiwork/gumroad/go_web/internal/sidekiq"
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
	// /l/:id/:code (an offer code), and a trailing slash, whose empty code goes to Rails.
	app.HandlePage("GET /l/{id}/{rest...}", "LinksController#show", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h.servePage(w, r, true)
	}))
}

type handler struct {
	c   *Config
	ctl *pages.Controller
}

// page is the controller instance for one request.
type page struct {
	*pages.Visit
	// seller is user_by_domain: the subdomain's or the custom domain's.
	seller *user
	// viewer is the signed-in visitor, nil when signed out.
	viewer *signedInUser
	// currentSeller is pundit_user's seller: the viewer, or the seller whose team they switched
	// to with teamRole.
	currentSeller *signedInUser
	teamRole      string
	// cacheWrites are the Rails.cache writes the render makes, made once it renders here.
	cacheWrites        []pendingWrite
	rates              map[string]rateRead
	hasCollaborator    bool
	hasInstallmentPlan bool
	hasPublicFiles     bool
	hasBundleProducts  bool
	hasAutoApplyCode   bool
	hasProductSections bool
	settleable         *settleability
	autoApply          *offerCode
	// codesLeft holds codeQuantityLeft's reads, by offer code.
	codesLeft map[int64]int64
	// flags holds pageFlag's reads.
	flags       map[string]bool
	productsKey string
	// warmReputation is snapshot_reputation_aggregate's perform_async, made once the page is
	// certain to render here.
	warmReputation bool
	// retinaPushes are the asset previews whose retina variant url_from_file enqueues, and
	// posterPushes those whose poster video_poster_url enqueues; avatarPushes the users whose
	// avatar_url enqueues GenerateAvatarVariantJob. viewerPushes are the signed-in props'
	// avatars, which Rails reads only for an Inertia render.
	retinaPushes, posterPushes, avatarPushes, viewerPushes []int64
	// urlCode is params[:code], the path's or the query's, when present.
	urlCode string
	// layout is params[:layout], and recommendedBy params[:recommended_by] when given: the page's
	// own, never a featured product's.
	layout        string
	recommendedBy *string
	// reviewPurchase is the review link's purchase, purchase_for_email_digest's, on the page itself
	// and not a featured section's, which Rails builds without the params.
	reviewPurchase *visitorPurchase
	// customDomain is a request on the seller's own custom domain, whose host the meta tags take;
	// productDomain one on a product's domain, whose links go to the seller's subdomain.
	customDomain, productDomain bool
	// utm is track_utm_link_visit's utm_params, nil when it records nothing.
	utm sidekiq.Hash
	// collaborates is whether the visitor is collaborator_for? this page's product.
	collaborates bool
	// visitorSearch is whether the query has a VISITOR_SEARCH_PARAMS key, which makes section_props
	// search afresh.
	visitorSearch bool
	// query is params[:query]: a string, or nil for a bare or absent key.
	query any
	// iframe is params[:overlay] || params[:embed], which renders Products/Iframe/Show.
	iframe bool
	// wanted is params[:wanted] == "true", which sends the visitor to checkout.
	wanted bool
	// format is request.format's symbol, which picks show's respond_to branch, and ext the
	// path's params[:format], "html" without one.
	format, ext string
	// catchAll is a path no /l/ route takes, which the catch-all's e404_page answers.
	catchAll bool
	// parent is the page's own view when this one renders a featured section's product within it.
	parent *view
}

type fallback = pages.Fallback

func (h *handler) ServeHTTP(w http.ResponseWriter, r *http.Request) { h.servePage(w, r, false) }

// servePage serves /l/:id, or /l/:id/:code on the code route.
func (h *handler) servePage(w http.ResponseWriter, r *http.Request, codeRoute bool) {
	ctx, cancel := context.WithTimeout(r.Context(), readTimeout)
	defer cancel()
	h.ctl.Serve(w, r, "product page", func(r *http.Request) (*pages.Visit, error) {
		p, err := h.prepare(ctx, r, codeRoute)
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
// dots it leaves unescaped taken literally.
var subdomainHost = regexp.MustCompile(`\A([a-z0-9-]+)\.gumroad\.com\z`)

// railsSubdomainHost is Subdomain.subdomain_request?'s pattern itself, whose unescaped dots
// also match a custom domain like mygumroad.com, which Rails then reads as a subdomain first.
var railsSubdomainHost = web.SubdomainRequestPattern("gumroad.com")

// analyticsHost is routes.rb's unanchored host constraint for THIRD_PARTY_ANALYTICS_DOMAIN,
// which a subdomain like gumroad-analytics-com.gumroad.com also meets, so Rails 404s it.
var analyticsHost = regexp.MustCompile(`gumroad-analytics.com`)

// permalinkParam is the shape of a code this port reads; anything else is Rails'.
var permalinkParam = regexp.MustCompile(`\A[A-Za-z0-9_-]+\z`)

// prepare parses the request and decides whether this port serves it. Nothing it does is
// visible outside the process, so any fallback it returns is safe.
func (h *handler) prepare(ctx context.Context, r *http.Request, codeRoute bool) (*page, error) {
	if h.c.Page == nil {
		return nil, fallback("pages off")
	}
	if codeRoute && r.URL.RawPath != "" && strings.Contains(r.PathValue("rest"), "/") {
		// An escaped slash stays in Journey's segment, which the mux's rest can't tell.
		return nil, fallback("offer code path")
	}
	rt := parseRoute(r.PathValue("id"), r.PathValue("rest"), codeRoute)
	if reason := declined(r, h.c.Env); reason != "" {
		return nil, fallback(reason)
	}
	if rt.catchAll {
		route := [][2]string{{"controller", "application"}, {"action", "e404_page"}, {"path", rt.path}}
		if rt.format != "" {
			route = append(route, [2]string{"format", rt.format})
		}
		v, err := h.ctl.Prepare(ctx, r, route, nil)
		if err != nil {
			return nil, err
		}
		return &page{Visit: v, catchAll: true}, nil
	}
	switch {
	case codeRoute && rt.code == "":
		// Journey drops the trailing slash, which this route doesn't.
		return nil, fallback("offer code path")
	case !validID(rt.id) || codeRoute && !validID(rt.code):
		return nil, fallback("permalink")
	}
	route := [][2]string{{"format", rt.format}, {"controller", "links"}, {"action", "show"}, {"id", rt.id}}
	if codeRoute {
		route = append(route, [2]string{"code", rt.code})
	}
	v, err := h.ctl.Prepare(ctx, r, route,
		func(req *rails.Request) error {
			if reason := declinedParams(req); reason != "" {
				return fallback(reason)
			}
			return nil
		})
	if err != nil {
		return nil, err
	}
	p := &page{Visit: v, format: v.Req.Format(), ext: rt.format}
	// The path's code overrides the query's; a blank one is no code.
	if code, _ := v.Req.Param("code").(string); rails.Present(code) {
		p.urlCode = code
	}
	if p.utm, _ = utmParams(v.Req); p.utm != nil && h.c.Page.Sidekiq == nil {
		return nil, fallback("utm visit push")
	}
	p.layout, _ = v.Req.Param("layout").(string)
	// A bare key is nil, which still counts as a visitor search param.
	if raw, ok := v.Req.Params.Get("recommended_by"); ok {
		by, _ := raw.(string)
		p.recommendedBy = &by
		p.visitorSearch = true
	}
	p.iframe = rails.Truthy(v.Req.Param("overlay")) || rails.Truthy(v.Req.Param("embed"))
	p.wanted = v.Req.Param("wanted") == "true"
	if raw, ok := v.Req.Params.Get("query"); ok {
		p.query, p.visitorSearch = raw, true
	}
	return p, nil
}

// parsedRoute is how Rails routes the path once Rack::UTF8Sanitizer has decoded its unreserved
// escapes, dots among them. /l/:id(.:format) and /l/:id/:code(.:format) segments stop at a dot,
// and what neither takes goes to the catch-all /(*path)(.:format).
type parsedRoute struct {
	id, code, format string
	catchAll         bool
	path             string
}

func parseRoute(id, rest string, codeRoute bool) parsedRoute {
	path, last := "l/"+id, id
	if codeRoute {
		path, last = path+"/"+rest, rest
	}
	// The format is the last segment's; every earlier one is a whole segment.
	name, format, ok := cutFormat(last)
	if codeRoute {
		ok = ok && !strings.Contains(id, ".") && !strings.Contains(rest, "/")
	}
	if ok {
		rt := parsedRoute{id: name, format: cmp.Or(format, "html")}
		if codeRoute {
			rt.id, rt.code = id, name
		}
		return rt
	}
	// The glob takes the last segment's extension as the format, when it has one.
	rt := parsedRoute{catchAll: true, path: path}
	last = path[strings.LastIndex(path, "/")+1:]
	if i := strings.LastIndex(last, "."); i >= 0 && i < len(last)-1 {
		rt.path, rt.format = path[:len(path)-len(last)+i], last[i+1:]
	}
	return rt
}

// cutFormat is a segment's name(.:format): ok is false for a dot no format follows, or a second.
func cutFormat(segment string) (name, format string, ok bool) {
	name, format, found := strings.Cut(segment, ".")
	return name, format, !found || format != "" && !strings.Contains(format, ".")
}

// validID is an id this port looks up as Rails does; one Rack::UTF8Sanitizer would rewrite,
// or with control characters, is Rails'.
func validID(id string) bool {
	return id != "" && utf8.ValidString(id) && !strings.ContainsFunc(id, unicode.IsControl)
}

// declined is everything decided by the request line and headers alone.
func declined(r *http.Request, env *web.Environment) string {
	host := web.Host(r)
	m := subdomainHost.FindStringSubmatch(host)
	subdomain := m != nil
	// A custom domain's request reaches Rails over plain http on port 80.
	port, protocol := "443", "https://"
	if !subdomain {
		port, protocol = "80", "http://"
	}
	switch {
	case r.Method != http.MethodGet:
		return "method"
	case env.RootDomain != "gumroad.com" || env.IsGumroadHost(host) || analyticsHost.MatchString(host):
		return "host"
	case subdomain && (m[1] == "www" || m[1] == "app"), !subdomain && railsSubdomainHost.MatchString(host):
		return "host"
	case !subdomain && r.Host == env.Domain:
		// Rack::SSL redirects a raw gumroad.com Host to https before routing.
		return "host"
	case r.Header.Get("X-Forwarded-Ssl") != "" || r.Header.Get("X-Forwarded-Scheme") != "":
		// Rack's scheme reads these; SecureHeaders' doesn't.
		return "forwarded scheme"
	case rails.SecureCookies(env.Protocol, r) != subdomain || web.Protocol(r) != protocol:
		return "not ssl"
	case web.HostWithPort(r) != host || web.ForwardedPort(r) != "" && web.ForwardedPort(r) != port:
		// Rails' URLs here would carry the port.
		return "port"
	case r.ContentLength != 0 || len(r.TransferEncoding) > 0:
		// Parsing reads the body, which a fallback after it could no longer send.
		return "request body"
	}
	return pages.DeclinedVisitHeaders(r)
}

// rendererParams are the params whose effect on the page this port leaves to Rails.
var rendererParams = []string{
	// The action and its presenter.
	"offer_code", "quantity", "currency", "option", "variant", "price", "recurrence", "rent", "native", "debug",
	// The sections' search filters.
	"tags", "filetypes", "min_price", "max_price", "rating", "sort", "from", "size",
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
	if raw, ok := req.Params.Get("layout"); ok {
		switch raw {
		case nil, "", productLayoutProfile, productLayoutDiscover:
		default:
			// Its value would go into the bundles' URLs.
			return "param layout"
		}
		// The layout's component with embed's iframe body class is neither port's shape.
		if (raw == productLayoutProfile || raw == productLayoutDiscover) && (rails.Truthy(req.Param("overlay")) || rails.Truthy(req.Param("embed"))) {
			return "layout with iframe"
		}
	}
	for _, name := range []string{"recommended_by", "query", "purchase_id", "purchase_email_digest"} {
		if raw, ok := req.Params.Get(name); ok {
			if _, isString := raw.(string); !isString && raw != nil {
				return "param " + name
			}
		}
	}
	// Only a code whose lookups can't depend on Unicode normalization or the collation is
	// served here.
	if raw, ok := req.Params.Get("code"); ok {
		if code, isString := raw.(string); !isString || !rails.Blank(code) && !permalinkParam.MatchString(code) {
			return "param code"
		}
	}
	if _, reason := utmParams(req); reason != "" {
		return reason
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
