package downloads

import (
	"net/http"
	"slices"
	"strings"

	"github.com/antiwork/gumroad/go_web/internal/delivery"
	"github.com/antiwork/gumroad/go_web/internal/inertia"
	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/session"
	"github.com/antiwork/gumroad/go_web/internal/web"
)

// serve runs ApplicationController's before_actions from redirect_to_custom_subdomain on,
// then the controller's, then the poll. It writes nothing until it knows the outcome, so
// a fallback it returns is still safe.
func (h *handler) serve(w http.ResponseWriter, p *page) error {
	req := p.req

	if p.auth.SellerCookieReset {
		p.cookies = append(p.cookies, rails.DeleteCookieLine(session.CurrentSellerCookie, rails.CookieDomainAll(req.Host), p.secure))
	}
	location, err := h.redirects.Location(p.req.HTTP)
	if err != nil {
		return err
	}
	if location != "" {
		return h.redirect(w, p, location)
	}

	if p.auth.LoggedInUser() == nil {
		setSignupReferrer(p, h.c.Env.RootDomain)
	}
	if _, ok := req.Cookie(guidCookie); !ok {
		p.cookies = append(p.cookies, rails.CookieLine(guidCookie, web.NewUUID(), rails.CookieDomainAll(req.Host), "",
			rails.AddYears(req.Now, 10), true, p.secure))
	}
	if p.session.Get(recommenderSessionKey) != recommenderModel {
		p.session.Set(recommenderSessionKey, recommenderModel)
	}

	u, path, err := h.checkPermissions(p)
	if err != nil {
		return err
	}
	if path != "" {
		if strings.HasPrefix(path, "/") {
			path = web.Protocol(p.req.HTTP) + web.HostWithPort(p.req.HTTP) + path
		}
		return h.redirect(w, p, path)
	}
	return h.render(w, p, u)
}

// redirect is redirect_to from a before_action: the session and the cookies set so far go
// out, nothing after it runs.
func (h *handler) redirect(w http.ResponseWriter, p *page, location string) error {
	if err := h.commit(w, p); err != nil {
		return err
	}
	rails.RedirectTo(w, p.req, location)
	return nil
}

// render is the poll's render(inertia:), set_noindex_header and the after_actions:
// inertia_rails' XSRF-TOKEN cookie, then the flash sweep and the session commit.
func (h *handler) render(w http.ResponseWriter, p *page, u *urlRedirect) error {
	props := rails.NewRHash().Sym("errors", rails.NewRHash())
	requested := rails.Split(p.req.HTTP.Header.Get("X-Inertia-Partial-Data"), ",")
	audio, locations := slices.Contains(requested, "audio_durations"), slices.Contains(requested, "latest_media_locations")
	var files []delivery.ProductFile
	// latest_media_locations_data returns {} before reading files when there's no purchase,
	// and reading them anyway could raise where Rails doesn't.
	if audio || (locations && p.purchase != nil) {
		var err error
		files, err = delivery.AliveProductFiles(p.ctx, h.c.DB, &delivery.Redirect{
			ID: u.id, PurchaseID: u.purchaseID, ProductID: u.productID, InstallmentID: u.installmentID, ImportedCustomerID: u.importedCustomerID,
		}, h.c.IDs)
		if err != nil {
			return err
		}
	}
	// requested_download_page_polling_props builds the hash in this order.
	if audio {
		props.Sym("audio_durations", delivery.AudioDurations(files, h.c.IDs))
	}
	if locations {
		var purchaseID *int64
		if p.purchase != nil {
			purchaseID = &p.purchase.id
		}
		// checkPermissions has handed redirects with an installment to Rails.
		positions, err := delivery.LatestMediaLocations(p.ctx, h.c.DB, purchaseID, false, files, h.c.IDs)
		if err != nil {
			return err
		}
		props.Sym("latest_media_locations", positions)
	}
	props.Sym("_inertia_meta", h.metaTags(p).JSON())
	body := inertia.Page(component, p.req.FullPath(), props)

	// prepare has checked the token decodes.
	masked, _ := session.MaskedGlobalToken(p.csrf)
	p.cookies = append(p.cookies, rails.SetCookie{Name: xsrfCookie, Value: masked}.Line(p.secure))
	// The share block read the flash, so whatever it held is swept.
	p.session.Delete("flash")
	if err := h.commit(w, p); err != nil {
		return err
	}
	w.Header().Set("X-Robots-Tag", "noindex")
	rails.RenderInertiaJSON(w, p.req, body)
	return nil
}

// commit writes the cookie jar, the session cookie last as the session middleware commits
// it into the jar. The CSRF token is stored first, as commit_csrf_token does. Rack::SSL
// adds HSTS to any response that didn't raise, on the app's own domain.
func (h *handler) commit(w http.ResponseWriter, p *page) error {
	if p.csrfFresh {
		p.session.Set(session.CSRFTokenKey, p.csrf)
	}
	line, err := h.c.Store.CommitLine(p.session, p.req.Host, p.secure, p.req.Now)
	if err != nil {
		return err
	}
	// Rack::SSL excludes by the raw Host header.
	if p.req.HTTP.Host == h.c.Env.Domain {
		w.Header().Set("Strict-Transport-Security", "max-age=31536000")
	}
	for _, c := range p.cookies {
		w.Header().Add("Set-Cookie", c)
	}
	if line != "" {
		w.Header().Add("Set-Cookie", line)
	}
	return nil
}

// setSignupReferrer is ApplicationController#set_signup_referrer.
func setSignupReferrer(p *page, rootDomain string) {
	if !rails.Blank(p.session.Get("signup_referrer")) {
		return
	}
	sref, hasSref := p.req.Params.Get("_sref")
	referrer := p.req.Referrer()
	if (!hasSref || sref == nil) && referrer == nil {
		return
	}
	if !rails.Blank(sref) {
		p.session.Set("signup_referrer", sref)
		return
	}
	if referrer == nil {
		return
	}
	if host, ok := rails.URIHost(*referrer); ok && host != "" && !strings.HasSuffix(host, rootDomain) {
		p.session.Set("signup_referrer", strings.ToLower(host))
	}
}
