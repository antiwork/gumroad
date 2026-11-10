package beacons

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/oauth"
	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/session"
	"github.com/antiwork/gumroad/go_web/internal/web"
)

const (
	guidCookie = "_gumroad_guid"
	// Real beacon payloads are under 2 KB; this leaves room without inviting big bodies.
	bodyLimit = 64 << 10
	// Puma has no per-request deadline, but these routes only read a few rows.
	readTimeout = 5 * time.Second
	// Writes outlive a client that hangs up, as they do under Puma.
	writeTimeout = 5 * time.Second
)

// action declares the route, the routing constraints and the before_actions a ported
// action runs.
type action struct {
	controller, name string
	scopes           scope
	checkSuspended   bool
	run              func(c *actionContext) error
}

// actionContext is the controller instance: the request plus what the before_actions
// left behind.
type actionContext struct {
	ctx context.Context
	w   http.ResponseWriter
	req *rails.Request
	// session is nil when absent, unreadable, nulled by CSRF or signed out.
	session     *session.Session
	nullSession bool
	scopes      scope
	auth        *session.Auth
	// token is ApplicationController#doorkeeper_token.
	token *oauth.Token
	// guidMinted is set_gumroad_guid having made the guid cookie for this request.
	guidMinted bool
}

var errNotFound = errors.New("not found")

type statusError int

func (s statusError) Error() string { return fmt.Sprintf("status %d", int(s)) }

func (h *handlers) handle(a action) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), readTimeout)
		defer cancel()
		if r.Body != nil {
			r.Body = http.MaxBytesReader(w, r.Body, bodyLimit)
		}
		c := &actionContext{ctx: ctx, w: w}
		if err := h.before(c, r, a); err != nil {
			h.fail(c, r, err)
			return
		}
		if c.req == nil {
			return
		}
		if err := a.run(c); err != nil {
			h.fail(c, r, err)
		}
	})
}

// before runs the routing constraints and the before_actions every ported action shares.
// It leaves c.req nil when one of them rendered.
func (h *handlers) before(c *actionContext, r *http.Request, a action) error {
	// Routing comes first: a request no route matches is a 404 whatever its params hold.
	host := web.Host(r)
	routed := !((r.Method == http.MethodGet || r.Method == http.MethodHead) && h.hosts.isThirdPartyAnalytics(host))
	pathParams := [][2]string{{"controller", a.controller}, {"action", a.name}}
	if id := r.PathValue("id"); id != "" {
		// Journey's :id segment stops at a dot.
		routed = routed && !strings.Contains(id, ".")
		pathParams = append(pathParams, [2]string{"id", id})
	}
	// The patterns spell out (.:format) as literal suffixes; Rails puts it in params.
	if last := r.URL.Path[strings.LastIndexByte(r.URL.Path, '/')+1:]; strings.Contains(last, ".") {
		pathParams = append(pathParams, [2]string{"format", last[strings.LastIndexByte(last, '.')+1:]})
	}
	if routed {
		var err error
		if c.scopes, err = h.hosts.scopes(c.ctx, host, a.scopes); err != nil {
			return err
		}
		routed = c.scopes != 0
	}

	req, err := h.stack.Parse(r, pathParams, h.now())
	if !routed {
		c.req = req
		return errNotFound
	}
	if err != nil {
		if h.stack.RenderParseError(c.w, r, err) {
			return nil
		}
		return err
	}
	c.req = req

	verified := req.Safe()
	var candidates []string
	if !verified {
		origin, hasOrigin := r.Header["Origin"]
		if hasOrigin && strings.Join(origin, ", ") == "null" {
			return statusError(http.StatusUnprocessableEntity)
		}
		if !hasOrigin || strings.Join(origin, ", ") == web.Protocol(r)+web.HostWithPort(r) {
			candidates = authenticityTokens(req)
		}
	}
	// The session is only decrypted when the request can use it.
	if raw, ok := req.Cookie(h.sessionCookie); ok && (verified || len(candidates) > 0) {
		c.session = h.codec.Load(h.sessionCookie, raw, req.Now)
	}
	if !verified && !validToken(c, candidates) {
		c.nullSession = true
		c.session = nil
		req.Cookies = map[string]*string{}
	}

	if err := h.authenticate(c); err != nil {
		return err
	}

	secure := rails.SecureCookies(h.deps.Env.Protocol, r)
	if c.auth.SellerCookieReset && !c.nullSession {
		c.w.Header().Add("Set-Cookie", rails.DeleteCookieLine(session.CurrentSellerCookie, rails.CookieDomainAll(req.Host), secure))
	}
	if c.auth.SessionInvalidated {
		// sign_out empties the session; Rails then redirects only on the app's own hosts.
		c.session = nil
		if c.scopes&scopeGumroad != 0 {
			rails.RedirectTo(c.w, req, web.Protocol(r)+web.HostWithPort(r)+"/login")
			c.req = nil
			return nil
		}
	}

	if a.checkSuspended {
		if logged := c.auth.LoggedInUser(); logged != nil && logged.Suspended() && !c.auth.Impersonating() && !req.Safe() {
			renderSuspended(c)
			c.req = nil
			return nil
		}
	}

	// set_gumroad_guid: domain :all, httponly, ten years.
	if _, ok := req.Cookie(guidCookie); !ok {
		guid := web.NewUUID()
		req.Cookies[guidCookie] = &guid
		c.guidMinted = true
		if !c.nullSession {
			c.w.Header().Add("Set-Cookie", rails.CookieLine(guidCookie, guid, rails.CookieDomainAll(req.Host), "",
				rails.AddYears(req.Now, 10), true, secure))
		}
	}
	return nil
}

// authenticityTokens are request_authenticity_tokens: the authenticity_token param when it
// is a String, and the X-CSRF-Token header. verified_request? only reads them when the
// Origin, if sent, is the base URL.
func authenticityTokens(req *rails.Request) []string {
	var candidates []string
	if token, ok := req.Param("authenticity_token").(string); ok {
		candidates = append(candidates, token)
	}
	if values, ok := req.HTTP.Header["X-Csrf-Token"]; ok {
		candidates = append(candidates, strings.Join(values, ", "))
	}
	return candidates
}

func validToken(c *actionContext, candidates []string) bool {
	real, _ := c.session.CSRFToken()
	for _, candidate := range candidates {
		if session.ValidAuthenticityToken(real, candidate, c.req.Path, c.req.Method) {
			return true
		}
	}
	return false
}

// authenticate resolves Doorkeeper's token, then the session's users.
func (h *handlers) authenticate(c *actionContext) error {
	req := c.req
	in := session.Input{Session: c.session, Now: req.Now}
	if raw, ok := oauth.FromRequest(req.Header("Authorization"), req.Param); ok {
		resource := h.deps.Env.Protocol + "://" + h.deps.Env.Domain + req.Path
		token, err := h.oauth.Bound(c.ctx, raw, resource, req.Now)
		if err != nil {
			return err
		}
		c.token = token
		// current_user_from_api_or_web falls back to the session's user when the token has
		// no owner, since current_api_user is nil then.
		if token != nil && token.ResourceOwnerID != nil {
			actor, err := token.Actor()
			if errors.Is(err, oauth.ErrOwnerNotFound) {
				return errNotFound
			}
			if err != nil {
				return err
			}
			in.APIActor, in.HasToken = actor, true
		}
	}
	if value, ok := req.Cookie(session.CurrentSellerCookie); ok {
		in.CurrentSellerValue = value
	}
	auth, err := h.resolver.Resolve(c.ctx, in)
	if err != nil {
		return err
	}
	c.auth = auth
	return nil
}

// renderSuspended is ApplicationController#check_suspended.
func renderSuspended(c *actionContext) {
	req := c.req
	if f := req.Format(); f != "html" && f != "json" {
		rails.Head(c.w, req, http.StatusOK)
		return
	}
	if rails.Negotiate(req.Formats, "html", "json") == "json" {
		rails.RenderStaticJSON(c.w, req, http.StatusOK, suspendedBody)
		return
	}
	// redirect_back(fallback_location: root_path), which only follows a same-host referer.
	base := web.Protocol(req.HTTP) + web.HostWithPort(req.HTTP)
	location := base + "/"
	if referer := req.Referrer(); referer != nil {
		if host, ok := rails.URIHost(*referer); ok && (host == req.Host || (host == "" && strings.HasPrefix(*referer, "/") && !strings.HasPrefix(*referer, "//"))) {
			location = *referer
			if strings.HasPrefix(location, "/") {
				location = base + location
			}
		}
	}
	rails.RedirectTo(c.w, req, location)
}

const suspendedMessage = "You can't perform this action because your account has been suspended."

var suspendedBody = rails.NewStatic(rails.EncodeJSON(rails.NewRHash().Sym("success", false).Sym("error_message", suspendedMessage)))

// fail renders what Rails renders for an exception raised in a before_action or action.
func (h *handlers) fail(c *actionContext, r *http.Request, err error) {
	req := c.req
	if req == nil {
		req = h.stack.Fallback(r)
	}
	var status statusError
	switch {
	case errors.Is(err, errNotFound):
		rails.RenderException(c.w, req, http.StatusNotFound)
	case errors.As(err, &status):
		rails.RenderException(c.w, req, int(status))
	default:
		if web.ClientLeft(c.w, r, err) {
			return
		}
		web.Logger(r).Error("beacon failed", "error", err.Error())
		rails.RenderException(c.w, req, http.StatusInternalServerError)
	}
}

func (h *handlers) now() time.Time { return h.deps.Now() }

// writeContext is the context a write runs under: not canceled with the request, but
// bounded on its own.
func (c *actionContext) writeContext() (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.WithoutCancel(c.ctx), writeTimeout)
}
