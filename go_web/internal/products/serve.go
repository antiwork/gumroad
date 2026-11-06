package products

import (
	"context"
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
	// user_by_domain scopes the permalink to the subdomain's seller.
	if exists, err := customDomainExists(ctx, conn, req.Host); err != nil || exists {
		return firstErr(err, fallback("custom domain"))
	}
	label := subdomainHost.FindStringSubmatch(req.Host)[1]
	if p.seller, err = subdomainSeller(ctx, conn, label); err != nil {
		return err
	}
	if p.seller == nil {
		// UserCustomDomainConstraint doesn't route a subdomain without a seller here.
		return fallback("no seller")
	}
	id, _ := req.Param("id").(string)
	prod, err := fetchLeniently(ctx, conn, id, p.seller.id)
	switch {
	case err != nil:
		return err
	case prod == nil, prod.bannedAt.Valid:
		// e404, and check_banned's.
		return pages.ErrNotFound
	case prod.userID != p.seller.id:
		// fetch_leniently is scoped to the seller, so ensure_seller_is_not_deleted and
		// ensure_domain_belongs_to_seller pass; anything else is Rails'.
		return fallback("seller mismatch")
	}

	// check_if_needs_redirect: on the seller's own subdomain only the permalink can differ.
	if permalink := prod.generalPermalink(); permalink != id {
		_, rawQuery, _ := strings.Cut(req.HTTP.RequestURI, "?")
		for i := 0; i < len(rawQuery); i++ {
			if c := rawQuery[i]; c <= ' ' || c >= 0x7f {
				return fallback("redirect query")
			}
		}
		target := web.Protocol(req.HTTP) + req.Host + "/l/" + web.EscapeSegment(permalink)
		if rawQuery != "" {
			target += "?" + rawQuery
		}
		if err := h.ctl.Commit(w, p.Visit); err != nil {
			return err
		}
		rails.RedirectWithStatus(w, req, target, http.StatusMovedPermanently)
		return nil
	}

	// product_custom_html_visible? for a visitor. A waitlist page shows it when it holds the
	// waitlist form, which is Rails' to find.
	if present, err := customHTMLPresent(ctx, conn, prod.id); err != nil {
		return err
	} else if present && (prod.alive() || prod.acceptsWaitlistSignups()) {
		on, err := h.flag(ctx, "custom_html_pages", p.seller.id)
		switch {
		case err != nil:
			return err
		case on && !prod.alive():
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
