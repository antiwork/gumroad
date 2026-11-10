package pages

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/inertia"
	"github.com/antiwork/gumroad/go_web/internal/oauth"
	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/session"
	"github.com/antiwork/gumroad/go_web/internal/web"
)

const (
	guidCookie            = "_gumroad_guid"
	rememberCookie        = "remember_user_token"
	xsrfCookie            = "XSRF-TOKEN"
	recommenderSessionKey = "recommender_model_name"
	// recommenderModel is RecommendedProductsService::MODELS' only entry.
	recommenderModel = "sales"
)

// Fallback is a reason to hand the request to Rails.
type Fallback string

func (f Fallback) Error() string { return string(f) }

// ErrNotFound is e404: neither the cookie jar nor the session is written.
var ErrNotFound = errors.New("not found")

// Controller is what ApplicationController reads besides the request.
type Controller struct {
	Env       *web.Environment
	Stack     *rails.Stack
	Store     *session.Store
	Resolver  *session.Resolver
	Proxy     *web.RailsProxy
	Redirects *web.SubdomainRedirects
	Meta      inertia.DefaultMeta
	Now       func() time.Time
	// DryRunKey signs dry-run requests, and DryRunOnce remembers the ones used; either
	// unset turns them off.
	DryRunKey  []byte
	DryRunOnce DryRunStore
}

// Visit is the controller instance for one request.
type Visit struct {
	Ctx     context.Context
	Req     *rails.Request
	Session *session.Session
	Auth    *session.Auth
	// csrf is the real token; csrfFresh means commit stores it.
	csrf      string
	csrfFresh bool
	// DryRun renders without writing, for a parity check.
	DryRun bool
	// Cookies are the Set-Cookie lines the cookie jar writes, in the order they were set.
	Cookies []string
	Secure  bool
	// MintedGUID is a _gumroad_guid set_gumroad_guid minted for this response, and GUID what
	// cookies[:_gumroad_guid] reads after it: the request's, or the minted one.
	MintedGUID bool
	GUID       string
}

// MaskedCSRFToken is form_authenticity_token.
func (p *Visit) MaskedCSRFToken() string {
	// Prepare has checked the token decodes.
	masked, _ := session.MaskedGlobalToken(p.csrf)
	return masked
}

// Serve runs serve and answers what it returns: Rails for a fallback (or the reason, for a
// dry run), e404, or a 500. serve passes r on to Prepare, which marks a dry run's Visit.
func (c *Controller) Serve(w http.ResponseWriter, r *http.Request, name string, serve func(r *http.Request) (*Visit, error)) {
	var dryRun bool
	switch c.dryRunState(r) {
	case dryRunRefused:
		answerDryRunFallback(w, "dry run refused")
		return
	case dryRunValid:
		dryRun = true
		r = r.WithContext(context.WithValue(r.Context(), dryRunKey{}, true))
	}
	p, err := serve(r)
	var reason Fallback
	switch {
	case err == nil:
	case errors.As(err, &reason) && dryRun:
		answerDryRunFallback(w, string(reason))
	case errors.As(err, &reason):
		c.Proxy.Forward(w, r, string(reason))
	case errors.Is(err, ErrNotFound) && p != nil:
		rails.RenderException(w, p.Req, http.StatusNotFound)
	default:
		if web.ClientLeft(w, r, err) {
			return
		}
		web.Logger(r).Error(name+" failed", "error", err.Error())
		req := c.Stack.Fallback(r)
		if p != nil {
			req = p.Req
		}
		rails.RenderException(w, req, http.StatusInternalServerError)
	}
}

// Prepare parses the request and runs what ApplicationController decides before any
// before_action writes: the API token checks, the session, the CSRF token and who is signed
// in. check runs on the parsed request first, for the action's own cheap fallbacks. Nothing
// it does is visible outside the process, so any fallback it returns is safe.
func (c *Controller) Prepare(ctx context.Context, r *http.Request, route [][2]string, check func(*rails.Request) error) (*Visit, error) {
	req, err := c.Stack.Parse(r, route, c.Now())
	if err != nil {
		return nil, Fallback("unparsed request")
	}
	if check != nil {
		if err := check(req); err != nil {
			return nil, err
		}
	}
	if _, ok := oauth.FromRequest(req.Header("Authorization"), req.Param); ok {
		// Doorkeeper's token decides logged_in_user, and access_token signs the mobile app in.
		return nil, Fallback("api token")
	}
	if _, ok := req.Params.Get("access_token"); ok {
		return nil, Fallback("param access_token")
	}
	if v, ok := req.Params.Get("_sref"); ok {
		if _, isString := v.(string); !isString {
			return nil, Fallback("param _sref")
		}
	}

	p := &Visit{Ctx: ctx, Req: req, Secure: rails.SecureCookies(c.Env.Protocol, r), DryRun: isDryRun(r)}
	if p.Session = c.Store.Load(req); p.Session == nil {
		p.Session = session.New()
	}
	for _, key := range []string{"inertia_errors", "inertia_clear_history"} {
		if p.Session.Get(key) != nil {
			return nil, Fallback("session " + key)
		}
	}

	if _, err := req.RemoteIP(); err != nil {
		// PaperTrail's controller info reads remote_ip first, and raises on spoofing.
		return nil, Fallback("remote ip")
	}
	switch token := p.Session.Get(session.CSRFTokenKey).(type) {
	case nil:
		p.csrf, p.csrfFresh = session.GenerateCSRFToken(), true
	case string:
		if _, ok := rails.URLSafeDecode64(token); !ok {
			return nil, Fallback("csrf token")
		}
		p.csrf = token
	default:
		return nil, Fallback("csrf token")
	}
	in := session.Input{Session: p.Session, Now: req.Now}
	if value, ok := req.Cookie(session.CurrentSellerCookie); ok {
		if c.Store.Codec.Rotated(session.CurrentSellerCookie, value) {
			return nil, Fallback("rotated " + session.CurrentSellerCookie)
		}
		in.CurrentSellerValue = value
	}
	if p.Auth, err = c.Resolver.Resolve(ctx, in); err != nil {
		return nil, err
	}
	switch {
	case p.Auth.CurrentUser != nil && p.Auth.CurrentUser.IsTeamMember():
		// authorize_rack_mini_profiler profiles team members.
		return nil, Fallback("team member")
	case p.Auth.CurrentUser == nil && req.HasCookie(rememberCookie):
		// Warden would sign the user in from the remember-me cookie.
		return nil, Fallback("remember me")
	case p.Auth.SessionInvalidated:
		return nil, Fallback("session invalidated")
	}
	return p, nil
}

// BeforeActions runs ApplicationController's before_actions from redirect_to_custom_subdomain
// through set_recommender_model_name. A non-empty location is the redirect it answers with.
func (c *Controller) BeforeActions(p *Visit) (location string, err error) {
	req := p.Req
	if p.Auth.SellerCookieReset {
		p.Cookies = append(p.Cookies, rails.DeleteCookieLine(session.CurrentSellerCookie, rails.CookieDomainAll(req.Host), p.Secure))
	}
	if location, err = c.Redirects.Location(req.HTTP); err != nil || location != "" {
		return location, err
	}
	if p.Auth.LoggedInUser() == nil {
		setSignupReferrer(p, c.Env.RootDomain)
	}
	if !req.HasCookie(guidCookie) {
		p.MintedGUID = true
		p.GUID = web.NewUUID()
		p.Cookies = append(p.Cookies, rails.CookieLine(guidCookie, p.GUID, rails.CookieDomainAll(req.Host), "",
			rails.AddYears(req.Now, 10), true, p.Secure))
	} else {
		p.GUID, _ = req.Cookie(guidCookie)
	}
	if p.Session.Get(recommenderSessionKey) != recommenderModel {
		p.Session.Set(recommenderSessionKey, recommenderModel)
	}
	return "", nil
}

// Redirect is redirect_to from a before_action: the session and the cookies set so far go
// out, nothing after it runs. A path is on the request's host.
func (c *Controller) Redirect(w http.ResponseWriter, p *Visit, location string) error {
	if strings.HasPrefix(location, "/") {
		location = web.Protocol(p.Req.HTTP) + web.HostWithPort(p.Req.HTTP) + location
	}
	if err := c.Commit(w, p); err != nil {
		return err
	}
	rails.RedirectTo(w, p.Req, location)
	return nil
}

// Finish is what follows a render: inertia_rails' XSRF-TOKEN cookie, the flash sweep and the
// session commit.
func (c *Controller) Finish(w http.ResponseWriter, p *Visit) error {
	p.Cookies = append(p.Cookies, rails.SetCookie{Name: xsrfCookie, Value: p.MaskedCSRFToken()}.Line(p.Secure))
	// The share block read the flash, so whatever it held is swept.
	p.Session.Delete("flash")
	return c.Commit(w, p)
}

// Commit writes the cookie jar, the session cookie last as the session middleware commits
// it into the jar. The CSRF token is stored first, as commit_csrf_token does. Rack::SSL
// adds HSTS to any response that didn't raise, on the app's own domain.
func (c *Controller) Commit(w http.ResponseWriter, p *Visit) error {
	if p.csrfFresh {
		p.Session.Set(session.CSRFTokenKey, p.csrf)
	}
	line, err := c.Store.CommitLine(p.Session, p.Req.Host, p.Secure, p.Req.Now)
	if err != nil {
		return err
	}
	// Rack::SSL excludes by the raw Host header.
	if p.Req.HTTP.Host == c.Env.Domain {
		w.Header().Set("Strict-Transport-Security", "max-age=31536000")
	}
	for _, line := range p.Cookies {
		w.Header().Add("Set-Cookie", line)
	}
	if line != "" {
		w.Header().Add("Set-Cookie", line)
	}
	return nil
}

// MetaTags are the before_actions' meta tags for this request.
func (c *Controller) MetaTags(p *Visit) *inertia.MetaTags {
	return c.Meta.Tags(c.Viewer(p))
}

// Viewer is what the default meta tags read about who is signed in.
func (c *Controller) Viewer(p *Visit) inertia.Viewer {
	v := inertia.Viewer{CSRFToken: p.MaskedCSRFToken()}
	if seller := p.Auth.CurrentSeller; seller != nil {
		v.HasSeller, v.SellerDisablesAnalytics = true, seller.DisableThirdPartyAnalytics()
	}
	if logged := p.Auth.LoggedInUser(); logged != nil {
		v.LoggedInUserID = logged.ExternalID
	}
	return v
}

// setSignupReferrer is ApplicationController#set_signup_referrer.
func setSignupReferrer(p *Visit, rootDomain string) {
	if !rails.Blank(p.Session.Get("signup_referrer")) {
		return
	}
	sref, hasSref := p.Req.Params.Get("_sref")
	referrer := p.Req.Referrer()
	if (!hasSref || sref == nil) && referrer == nil {
		return
	}
	if !rails.Blank(sref) {
		p.Session.Set("signup_referrer", sref)
		return
	}
	if referrer == nil {
		return
	}
	if host, ok := rails.URIHost(*referrer); ok && host != "" && !strings.HasSuffix(host, rootDomain) {
		p.Session.Set("signup_referrer", strings.ToLower(host))
	}
}

// DeclinedHeaders is what Rails reads from the headers that a full-page render here leaves
// to Rails: any Inertia visit or partial reload, which inertia_rails reads without checking
// X-Inertia, and a Forwarded header.
func DeclinedHeaders(r *http.Request) string {
	if r.Header.Get("X-Inertia") != "" {
		return "inertia visit"
	}
	return DeclinedVisitHeaders(r)
}

// DeclinedVisitHeaders is DeclinedHeaders for a page that answers a plain Inertia visit itself:
// a blank X-Inertia, which the renderer and the middleware read differently, and the rest.
func DeclinedVisitHeaders(r *http.Request) string {
	if v, ok := r.Header["X-Inertia"]; ok && rails.Blank(strings.Join(v, "")) {
		return "inertia visit"
	}
	// Rack reads the host, scheme and port from Forwarded before the X-Forwarded headers.
	if _, ok := r.Header["Forwarded"]; ok {
		return "forwarded header"
	}
	for _, h := range []string{"X-Inertia-Partial-Component", "X-Inertia-Partial-Data", "X-Inertia-Partial-Except",
		"X-Inertia-Reset", "X-Inertia-Version", "X-Inertia-Error-Bag"} {
		if _, ok := r.Header[h]; ok {
			return "inertia header " + h
		}
	}
	return ""
}

// DeclinedPartialHeaders is DeclinedVisitHeaders for a page that answers one partial reload
// itself: an Inertia visit for component's data and nothing else.
func DeclinedPartialHeaders(r *http.Request, component, data string) string {
	if r.Header.Get("X-Inertia") == "" {
		// The renderer filters the props whether or not the request is an Inertia visit.
		return "inertia partial without X-Inertia"
	}
	if v := r.Header.Values("X-Inertia-Partial-Component"); len(v) != 1 || v[0] != component {
		return "inertia header X-Inertia-Partial-Component"
	}
	if v := r.Header.Values("X-Inertia-Partial-Data"); len(v) != 1 || v[0] != data {
		return "inertia header X-Inertia-Partial-Data"
	}
	h := r.Header.Clone()
	h.Del("X-Inertia-Partial-Component")
	h.Del("X-Inertia-Partial-Data")
	return DeclinedVisitHeaders(&http.Request{Header: h})
}
