// Package downloads serves the download page's background polls: GET /d/:token as an
// Inertia partial reload of audio_durations and latest_media_locations
// (UrlRedirectsController#download_page). Everything else that reaches it, and every
// request whose Rails path this port leaves out, goes to Rails unchanged before anything
// is written.
package downloads

import (
	"context"
	"database/sql"
	"errors"
	"net/http"
	"slices"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/inertia"
	"github.com/antiwork/gumroad/go_web/internal/oauth"
	"github.com/antiwork/gumroad/go_web/internal/obfuscate"
	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/session"
	"github.com/antiwork/gumroad/go_web/internal/web"
)

const (
	component = "UrlRedirects/DownloadPage"
	// Puma has no per-request deadline, but a poll reads a handful of rows.
	readTimeout = 5 * time.Second

	guidCookie            = "_gumroad_guid"
	rememberCookie        = "remember_user_token"
	confirmedCookie       = "confirmed_redirect"
	xsrfCookie            = "XSRF-TOKEN"
	recommenderSessionKey = "recommender_model_name"
	recommenderModel      = "sales"
)

// pollProps is DOWNLOAD_PAGE_POLLING_PROPS.
var pollProps = []string{"audio_durations", "latest_media_locations"}

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
	// Pages is the full page's config, nil to leave every full page to Rails.
	Pages *PageConfig
	// DryRunKey signs dry-run requests; empty turns them off.
	DryRunKey []byte
}

func Register(app *web.App, c *Config) {
	app.HandlePage("GET /d/{id}", "UrlRedirectsController#download_page", &handler{c: c, redirects: app.Redirects()})
}

type handler struct {
	c         *Config
	redirects *web.SubdomainRedirects
}

// page is the controller instance for one request.
type page struct {
	ctx     context.Context
	req     *rails.Request
	session *session.Session
	auth    *session.Auth
	// csrf is the real token; csrfFresh means commit stores it.
	csrf      string
	csrfFresh bool
	// purchase is url_redirect.purchase once checkPermissions has loaded it.
	purchase *purchase
	// poll is a background poll; anything else is the full page.
	poll bool
	// dryRun renders without writing, for a parity check.
	dryRun bool
	// cookies are the Set-Cookie lines the cookie jar writes, in the order they were set.
	cookies []string
	secure  bool
}

// fallback is a reason to hand the request to Rails.
type fallback string

func (f fallback) Error() string { return string(f) }

var errNotFound = errors.New("not found")

func (h *handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), readTimeout)
	defer cancel()
	dryRun := h.dryRun(r)
	p, err := h.prepare(ctx, r)
	if err == nil {
		p.dryRun = dryRun
		err = h.serve(w, p)
	}
	var reason fallback
	switch {
	case err == nil:
	case errors.As(err, &reason) && dryRun:
		answerDryRunFallback(w, string(reason))
	case errors.As(err, &reason):
		h.c.Proxy.Forward(w, r, string(reason))
	case errors.Is(err, errNotFound):
		// e404 raises, so neither the cookie jar nor the session is written.
		rails.RenderException(w, p.req, http.StatusNotFound)
	default:
		web.Logger(r).Error("download page poll failed", "error", err.Error())
		req := h.c.Stack.Fallback(r)
		if p != nil {
			req = p.req
		}
		rails.RenderException(w, req, http.StatusInternalServerError)
	}
}

// prepare parses the request and decides whether this port serves it. Nothing it does is
// visible outside the process, so any fallback it returns is safe.
func (h *handler) prepare(ctx context.Context, r *http.Request) (*page, error) {
	if reason := declined(r, h.c.Env, h.c.Pages != nil); reason != "" {
		return nil, fallback(reason)
	}
	req, err := h.c.Stack.Parse(r, [][2]string{{"controller", "url_redirects"}, {"action", "download_page"}, {"id", r.PathValue("id")}}, h.c.Now())
	if err != nil {
		return nil, fallback("unparsed request")
	}
	if req.Format() != "html" {
		return nil, fallback("format")
	}
	if _, ok := oauth.FromRequest(req.Header("Authorization"), req.Param); ok {
		// Doorkeeper's token decides logged_in_user, and access_token signs the mobile app in.
		return nil, fallback("api token")
	}
	if _, ok := req.Params.Get("access_token"); ok {
		return nil, fallback("param access_token")
	}
	for _, key := range []string{"_sref", "display"} {
		if v, ok := req.Params.Get(key); ok {
			if _, isString := v.(string); !isString {
				return nil, fallback("param " + key)
			}
		}
	}

	p := &page{ctx: ctx, req: req, secure: rails.SecureCookies(h.c.Env.Protocol, r), poll: pollRequest(r)}
	if p.session = h.c.Store.Load(req); p.session == nil {
		p.session = session.New()
	}
	for _, key := range []string{"inertia_errors", "inertia_clear_history"} {
		if p.session.Get(key) != nil {
			return nil, fallback("session " + key)
		}
	}

	if _, err := req.RemoteIP(); err != nil {
		// PaperTrail's controller info reads remote_ip first, and raises on spoofing.
		return nil, fallback("remote ip")
	}
	switch token := p.session.Get(session.CSRFTokenKey).(type) {
	case nil:
		p.csrf, p.csrfFresh = session.GenerateCSRFToken(), true
	case string:
		if _, ok := rails.URLSafeDecode64(token); !ok {
			return nil, fallback("csrf token")
		}
		p.csrf = token
	default:
		return nil, fallback("csrf token")
	}
	for _, name := range []string{session.CurrentSellerCookie, confirmedCookie} {
		if value, ok := req.Cookie(name); ok && h.c.Store.Codec.Rotated(name, value) {
			return nil, fallback("rotated " + name)
		}
	}

	in := session.Input{Session: p.session, Now: req.Now}
	if value, ok := req.Cookie(session.CurrentSellerCookie); ok {
		in.CurrentSellerValue = value
	}
	if p.auth, err = h.c.Resolver.Resolve(ctx, in); err != nil {
		return nil, err
	}
	switch {
	case p.auth.CurrentUser != nil && p.auth.CurrentUser.IsTeamMember():
		// authorize_rack_mini_profiler profiles team members.
		return nil, fallback("team member")
	case p.auth.CurrentUser == nil && hasCookie(req, rememberCookie):
		// Warden would sign the user in from the remember-me cookie.
		return nil, fallback("remember me")
	case p.auth.SessionInvalidated:
		return nil, fallback("session invalidated")
	}
	return p, nil
}

// declined is everything decided by the request line and headers alone. pages is whether
// this port renders the full page, which an Inertia visit to it still leaves to Rails.
func declined(r *http.Request, env *web.Environment, pages bool) string {
	host := web.Host(r)
	switch {
	case r.Method != http.MethodGet:
		return "method"
	case !env.IsGumroadHost(host):
		return "host"
	case !alnumToken(r.PathValue("id")):
		return "token"
	case !rails.SecureCookies(env.Protocol, r):
		// Rack::SSL redirects plain HTTP, and the session only commits over SSL.
		return "not ssl"
	case !pollRequest(r) && (!pages || r.Header.Get("X-Inertia") != "" || hasPartialHeaders(r)):
		// inertia_rails reads the partial headers without X-Inertia, so Rails would render
		// a partial page here.
		return "not a poll"
	case r.ContentLength != 0 || len(r.TransferEncoding) > 0:
		// Parsing reads the body, which a fallback after it could no longer send.
		return "request body"
	}
	for _, h := range []string{"X-Inertia-Version", "X-Inertia-Partial-Except", "X-Inertia-Error-Bag"} {
		if _, ok := r.Header[h]; ok {
			return "inertia header " + h
		}
	}
	// Rails reads a repeated header joined with ", ", which is no longer a poll.
	for _, h := range []string{"X-Inertia", "X-Inertia-Partial-Component", "X-Inertia-Partial-Data"} {
		if len(r.Header.Values(h)) > 1 {
			return "repeated " + h
		}
	}
	return ""
}

// alnumToken is what UrlRedirect tokens look like; anything else needs Rails' path escaping.
func alnumToken(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z') {
			return false
		}
	}
	return true
}

// pollRequest is download_page_polling_request?. Ruby's split drops trailing empty fields.
func pollRequest(r *http.Request) bool {
	if r.Header.Get("X-Inertia") != "true" || r.Header.Get("X-Inertia-Partial-Component") != component {
		return false
	}
	props := rails.Split(r.Header.Get("X-Inertia-Partial-Data"), ",")
	if len(props) == 0 {
		// download_page_polling_request? accepts it, but inertia_rails then renders every prop.
		return false
	}
	for _, prop := range props {
		if !slices.Contains(pollProps, prop) {
			return false
		}
	}
	return true
}

func hasCookie(req *rails.Request, name string) bool {
	_, ok := req.Cookie(name)
	return ok
}

// hasPartialHeaders is a request inertia_rails would answer as a partial reload, which it
// reads without checking X-Inertia.
func hasPartialHeaders(r *http.Request) bool {
	for _, h := range []string{"X-Inertia-Partial-Component", "X-Inertia-Partial-Data", "X-Inertia-Partial-Except", "X-Inertia-Reset"} {
		if _, ok := r.Header[h]; ok {
			return true
		}
	}
	return false
}
