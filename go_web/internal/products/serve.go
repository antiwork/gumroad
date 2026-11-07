package products

import (
	"context"
	"database/sql"
	"errors"
	"net/http"
	"strings"

	"github.com/antiwork/gumroad/go_web/internal/pages"
	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/web"
)

// serve runs ApplicationController's before_actions from redirect_to_custom_subdomain on,
// then LinksController#show's filters in order, then the action. Everything before the
// render only reads, so a fallback it returns is still safe.
func (h *handler) serve(w http.ResponseWriter, p *page) error {
	location, err := h.ctl.BeforeActions(p.Visit)
	if err != nil {
		return err
	}
	if location != "" {
		return h.ctl.Redirect(w, p.Visit, location)
	}
	if p.catchAll {
		// e404_page raises after ApplicationController's filters.
		return pages.ErrNotFound
	}
	ctx, conn, req := p.Ctx, h.c.DB, p.Req

	// fetch_product_for_show: a product custom domain's product comes first, and
	// user_by_domain scopes the permalink to the subdomain's or custom domain's seller.
	var prod *product
	if m := subdomainHost.FindStringSubmatch(req.Host); m == nil {
		if prod, err = h.resolveCustomDomain(p); err != nil {
			return err
		}
	} else {
		if d, err := findCustomDomain(ctx, conn, req.Host); err != nil || d != nil {
			return firstErr(err, fallback("custom domain"))
		}
		if p.seller, err = subdomainSeller(ctx, conn, m[1]); err != nil {
			return err
		}
		if p.seller == nil {
			// UserCustomDomainConstraint doesn't route it here: the catch-all route's e404_page raises
			// the same RoutingError after the same filters.
			return pages.ErrNotFound
		}
	}
	id, _ := req.Param("id").(string)
	if !p.productDomain {
		if prod, err = fetchLeniently(ctx, conn, id, p.seller.id); err != nil {
			return err
		}
	}
	switch {
	case prod != nil && prod.bannedAt.Valid:
		// track_utm_link_visit records a visit before check_banned's 404.
		return firstErr(h.trackUTMVisit(w, p, prod), pages.ErrNotFound)
	case prod == nil:
		// e404, and check_banned's.
		return pages.ErrNotFound
	case p.seller.deletedAt.Valid && p.utm != nil:
		// A custom domain's: track_utm_link_visit may record a visit before the 404.
		return fallback("utm visit for a deleted seller")
	case p.seller.deletedAt.Valid:
		// ensure_seller_is_not_deleted.
		return pages.ErrNotFound
	case prod.userID != p.seller.id:
		// fetch_leniently is scoped to the seller, so ensure_seller_is_not_deleted and
		// ensure_domain_belongs_to_seller pass; anything else is Rails'.
		return fallback("seller mismatch")
	}
	// set_affiliate_cookie: a redirect and the custom HTML page carry the cookie too.
	if err := h.setAffiliateCookie(p); err != nil {
		return err
	}

	// check_if_needs_redirect: on the seller's own host only the permalink can differ, and a
	// product's domain never redirects.
	if permalink := prod.generalPermalink(); permalink != id && !p.productDomain {
		_, rawQuery, _ := strings.Cut(req.HTTP.RequestURI, "?")
		for i := 0; i < len(rawQuery); i++ {
			if c := rawQuery[i]; c <= ' ' || c >= 0x7f {
				return fallback("redirect query")
			}
		}
		target := h.shortLinkURL(p, permalink)
		if p.urlCode != "" {
			target += "/" + web.EscapeSegment(p.urlCode)
			// set_x_robots_tag_header runs before check_if_needs_redirect.
			w.Header().Set("X-Robots-Tag", "noindex")
		}
		if p.ext != "html" {
			// short_link_url's format: params[:format], which it leaves out at the route's default.
			target += "." + web.EscapeSegment(p.ext)
		}
		if rawQuery != "" {
			target += "?" + rawQuery
		}
		if err := h.trackUTMVisit(w, p, prod); err != nil {
			return err
		}
		if err := h.ctl.Commit(w, p.Visit); err != nil {
			return err
		}
		rails.RedirectWithStatus(w, req, target, http.StatusMovedPermanently)
		return nil
	}

	if p.autocomplete && p.format != "html" {
		return fallback("inertia partial reload")
	}
	if p.format != "html" {
		// render_custom_html_if_present only intercepts HTML.
		return h.renderFormat(w, p, prod)
	}
	if p.reviewPurchase, err = h.digestPurchase(p, prod); err != nil {
		return err
	}
	// product_custom_html_visible?: the seller and collaborators preview it whatever the
	// product's state, and a waitlist page shows it when it holds the waitlist form. Either way
	// it renders before show's coffee redirect, unless a review link needs the standard page's
	// form.
	logged := p.Auth.LoggedInUser()
	seller := logged != nil && logged.ID == prod.userID
	pageHTML, err := productCustomHTML(ctx, conn, prod.id)
	if err != nil {
		return err
	}
	// ?native=true opens the standard page instead.
	if rails.Present(pageHTML) && !p.wanted && p.Req.Param("native") != "true" && p.reviewPurchase == nil &&
		(prod.alive() || logged != nil || prod.acceptsWaitlistSignups()) {
		// ?wanted=true goes on to show, which sends the buyer to checkout.
		on, err := h.flag(ctx, "custom_html_pages", p.seller.id)
		switch {
		case err != nil:
			return err
		case on && !prod.alive() && !seller:
			// can_preview_product_custom_html?: a collaborator previews it, which renderCustomHTML
			// leaves to Rails, as staff went there already; anyone else gets show's page unless the
			// custom page collects waitlist signups.
			if logged != nil {
				collaborates, err := h.collaboratorFor(ctx, logged.ID, prod.id)
				if err != nil {
					return err
				}
				if collaborates {
					return h.renderCustomHTML(w, p, prod)
				}
			}
			if !prod.acceptsWaitlistSignups() {
				break
			}
			found, err := waitlistFormFound(pageHTML)
			if err != nil {
				return err
			}
			if found {
				return h.renderCustomHTML(w, p, prod)
			}
		case on:
			return h.renderCustomHTML(w, p, prod)
		}
	}
	return h.render(w, p, prod)
}

// scanFirst scans the first row of a LIMIT 2 query into dest; n is how many rows there were,
// for a has_one Rails takes in no order.
func (h *handler) scanFirst(ctx context.Context, dest []any, query string, args ...any) (n int, err error) {
	rows, err := h.c.DB.QueryContext(ctx, query, args...)
	if err != nil {
		return 0, err
	}
	defer rows.Close()
	for rows.Next() {
		if n++; n == 1 {
			if err := rows.Scan(dest...); err != nil {
				return 0, err
			}
		}
	}
	return n, rows.Err()
}

func firstErr(err, otherwise error) error {
	if err != nil {
		return err
	}
	return otherwise
}

// resolveCustomDomain resolves a custom domain as routing and fetch_product_for_show do: a
// product's domain renders that product whatever the path names, and a seller's scopes the
// permalink to its owner.
func (h *handler) resolveCustomDomain(p *page) (*product, error) {
	ctx, conn := p.Ctx, h.c.DB
	d, err := findCustomDomain(ctx, conn, p.Req.Host)
	switch {
	case err != nil:
		return nil, err
	case d == nil:
		return nil, fallback("no custom domain")
	case d.productID.Valid && d.userID.Valid:
		// UTM tracking and url_for_product_page would read its user too.
		return nil, fallback("custom domain with a product and a user")
	case d.productID.Valid:
		return h.productDomainProduct(p, d.productID.Int64)
	case !d.userID.Valid:
		return nil, fallback("no custom domain owner")
	}
	seller, err := userByID(ctx, conn, d.userID.Int64)
	switch {
	case err != nil:
		return nil, err
	case seller == nil:
		return nil, fallback("no custom domain owner")
	}
	p.seller, p.customDomain = seller, true
	return nil, nil
}

// productDomainProduct is product_by_custom_domain: the domain's product, fetched leniently by
// its general permalink under its seller. track_utm_link_visit records nothing here, since
// UserCustomDomainConstraint finds no seller for the host.
func (h *handler) productDomainProduct(p *page, productID int64) (*product, error) {
	ctx, conn := p.Ctx, h.c.DB
	domainProduct := &product{}
	err := conn.QueryRowContext(ctx, "SELECT links.user_id, links.unique_permalink, links.custom_permalink FROM links WHERE links.id = ? LIMIT 1",
		productID).Scan(&domainProduct.userID, &domainProduct.uniquePermalink, &domainProduct.customPermalink)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, fallback("product custom domain without a product")
	}
	if err != nil {
		return nil, err
	}
	permalink := domainProduct.generalPermalink()
	if rails.Blank(permalink) {
		return nil, fallback("product custom domain without a permalink")
	}
	prod, err := fetchLeniently(ctx, conn, permalink, domainProduct.userID)
	switch {
	case err != nil:
		return nil, err
	case prod == nil:
		// Rails then fetches the path's permalink among every seller's products.
		return nil, fallback("product custom domain without an alive product")
	}
	seller, err := userByID(ctx, conn, prod.userID)
	switch {
	case err != nil:
		return nil, err
	case seller == nil:
		// ensure_seller_is_not_deleted raises on a nil user.
		return nil, fallback("product custom domain seller deleted")
	case seller.deletedAt.Valid:
		// ensure_seller_is_not_deleted's 404, with no UTM visit recorded on a product's domain.
		p.utm = nil
		return nil, pages.ErrNotFound
	}
	p.seller, p.productDomain, p.utm = seller, true, nil
	return prod, nil
}
