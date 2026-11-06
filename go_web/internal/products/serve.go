package products

import (
	"context"
	"database/sql"
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
	ctx, conn, req := p.Ctx, h.c.DB, p.Req

	// fetch_product_for_show: a product custom domain's product comes first, and
	// user_by_domain scopes the permalink to the subdomain's or custom domain's seller.
	if m := subdomainHost.FindStringSubmatch(req.Host); m == nil {
		if p.seller, err = customDomainSeller(ctx, conn, req.Host); err != nil {
			return err
		}
		p.customDomain = true
	} else {
		if d, err := findCustomDomain(ctx, conn, req.Host); err != nil || d != nil {
			return firstErr(err, fallback("custom domain"))
		}
		if p.seller, err = subdomainSeller(ctx, conn, m[1]); err != nil {
			return err
		}
		if p.seller == nil {
			// UserCustomDomainConstraint doesn't route a subdomain without a seller here.
			return fallback("no seller")
		}
	}
	id, _ := req.Param("id").(string)
	prod, err := fetchLeniently(ctx, conn, id, p.seller.id)
	switch {
	case err != nil:
		return err
	case prod != nil && prod.bannedAt.Valid && p.utm != nil:
		// track_utm_link_visit records a visit before check_banned's 404.
		return fallback("utm visit on a banned product")
	case prod == nil, prod.bannedAt.Valid:
		// e404, and check_banned's.
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

	// check_if_needs_redirect: on the seller's own host only the permalink can differ.
	if permalink := prod.generalPermalink(); permalink != id {
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

	// product_custom_html_visible?: the seller and collaborators preview it whatever the
	// product's state, and a waitlist page shows it when it holds the waitlist form, which is
	// Rails' to find. Either way it renders before show's coffee redirect.
	logged := p.Auth.LoggedInUser()
	seller := logged != nil && logged.ID == prod.userID
	if present, err := customHTMLPresent(ctx, conn, prod.id); err != nil {
		return err
	} else if present && !p.wanted && (prod.alive() || logged != nil || prod.acceptsWaitlistSignups()) {
		// ?wanted=true goes on to show, which sends the buyer to checkout.
		on, err := h.flag(ctx, "custom_html_pages", p.seller.id)
		switch {
		case err != nil:
			return err
		case on && !prod.alive() && logged != nil && !seller:
			// A collaborator previews it, which renderCustomHTML leaves to Rails; anyone else gets the
			// page, which isn't ported for an unpublished product here.
			return fallback("custom html preview")
		case on && !prod.alive() && !seller:
			return fallback("custom html waitlist")
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

// customDomainSeller is user_by_domain on a seller's custom domain, which
// UserCustomDomainConstraint routes here when its owner has a username.
func customDomainSeller(ctx context.Context, conn *sql.DB, host string) (*user, error) {
	d, err := findCustomDomain(ctx, conn, host)
	switch {
	case err != nil:
		return nil, err
	case d == nil:
		return nil, fallback("no custom domain")
	case d.productID.Valid:
		// The product's own domain renders that product whatever the path names.
		return nil, fallback("product custom domain")
	case !d.userID.Valid:
		return nil, fallback("no custom domain owner")
	}
	seller, err := userByID(ctx, conn, d.userID.Int64)
	switch {
	case err != nil:
		return nil, err
	case seller == nil || rails.Blank(seller.username.String):
		return nil, fallback("no custom domain owner")
	case seller.deletedAt.Valid:
		// Rails 404s it in ensure_seller_is_not_deleted.
		return nil, fallback("deleted custom domain owner")
	}
	return seller, nil
}
