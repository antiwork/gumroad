package products

import (
	"context"
	"database/sql"
	"strings"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/db"
	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/session"
	"github.com/antiwork/gumroad/go_web/internal/web"
)

// The X player card's size, PageMeta::Product::DEMO_PLAYER_CARD_WIDTH and _HEIGHT.
const demoPlayerWidth, demoPlayerHeight = 640, 480

// provenAccountAge is ContentModeration::GumroadImpersonation::PROVEN_ACCOUNT_AGE.
const provenAccountAge = 30 * 24 * time.Hour

// demoPlayerURL is demo_player_card_meta's twitter:player, "" without a card: the demo page of
// ProductBuild.demo_for's build when demo? holds.
func (h *handler) demoPlayerURL(p *page, prod *product, v *view) (string, error) {
	ctx := p.Ctx
	if on, err := h.flag(ctx, "product_build_demo", prod.userID); err != nil || !on {
		return "", err
	}
	type build struct {
		status             string
		selected, unpacked db.NullTime
	}
	// min_by keeps the first chosen build in the statement's order, else the first live one.
	var pick *build
	err := scanNamed(ctx, h.c.DB, func(cols map[string]any) func() {
		b := &build{}
		cols["status"], cols["demo_selected_at"], cols["site_unpacked_at"] = &b.status, &b.selected, &b.unpacked
		return func() {
			if pick == nil || b.selected.Valid && !pick.selected.Valid {
				pick = b
			}
		}
	}, "SELECT `product_builds`.* FROM `product_builds` WHERE `product_builds`.`product_id` = ?"+
		" AND (`product_builds`.`demo_selected_at` IS NOT NULL OR `product_builds`.`status` = 'live')"+
		" ORDER BY `product_builds`.`number` ASC", prod.id)
	if err != nil || pick == nil {
		return "", err
	}
	player, err := h.flag(ctx, "product_build_player", prod.userID)
	if err != nil || !player || !pick.unpacked.Valid || !onSale(prod, p.seller) {
		return "", err
	}
	if unproven, err := h.unprovenSeller(p, p.seller); err != nil || unproven {
		return "", err
	}
	live, free := pick.status == "live", false
	if live {
		if free, err = h.freeProduct(ctx, prod, v); err != nil {
			return "", err
		}
	}
	// A chosen build is the demo unless it's what buyers of a paid product get. Without one,
	// which min_by would have taken, a free product's live build is.
	if pick.selected.Valid && live && !free || !pick.selected.Valid && !(live && free) {
		return "", nil
	}
	return h.c.Env.Protocol + "://" + h.c.Env.Domain + "/demo/" + web.EscapeSegment(h.c.IDs.Encrypt(prod.id)), nil
}

// onSale is ProductBuild#on_sale?.
func onSale(prod *product, seller *user) bool {
	return prod.published() && !prod.bannedAt.Valid && !prod.is(productIsInPreorderState) && !seller.deletedAt.Valid &&
		!session.SuspendedRiskState(seller.riskState.String)
}

// unprovenSeller is GumroadImpersonation.unproven_seller?: an account younger than
// PROVEN_ACCOUNT_AGE without a paid sale, unless it's confirmed Gumroad staff.
func (h *handler) unprovenSeller(p *page, seller *user) (bool, error) {
	var createdAt, confirmedAt db.NullTime
	var email sql.NullString
	if err := h.c.DB.QueryRowContext(p.Ctx, "SELECT users.created_at, users.confirmed_at, users.email FROM users WHERE users.id = ?",
		seller.id).Scan(&createdAt, &confirmedAt, &email); err != nil {
		return false, err
	}
	if confirmedAt.Valid && strings.HasSuffix(rails.Downcase(email.String), "@gumroad.com") {
		return false, nil
	}
	if createdAt.Valid && !createdAt.Time.After(p.Req.Now.Add(-provenAccountAge)) {
		return false, nil
	}
	// user.sales.paid.exists?
	paid, err := h.exists(p.Ctx, "SELECT 1 FROM purchases WHERE purchases.seller_id = ? AND purchases.purchase_state = 'successful'"+
		" AND purchases.price_cents > 0 AND (stripe_refunded is null OR stripe_refunded = 0) LIMIT 1", seller.id)
	return !paid, err
}

// freeProduct is ProductBuild.free_product?: free whatever version a buyer picks. A rental's price
// is no buy price, so prices.buy stands for price_cents past the rent-only check.
func (h *handler) freeProduct(ctx context.Context, prod *product, v *view) (bool, error) {
	if prod.rentOnly() || prod.is(productIsRecurringBilling) || v.prices.buy == nil || *v.prices.buy != 0 {
		return false, nil
	}
	ids := make([]int64, 0, len(v.variants.all))
	for _, o := range v.variants.all {
		if o.priceDifference.Int64 > 0 {
			return false, nil
		}
		ids = append(ids, o.id)
	}
	if len(ids) == 0 {
		return true, nil
	}
	paid, err := h.exists(ctx, "SELECT 1 FROM prices WHERE prices.variant_id IN ("+placeholders(len(ids))+") AND prices.deleted_at IS NULL"+
		" AND (prices.flags & ? = 0) AND prices.price_cents > 0 LIMIT 1", append(int64Args(ids), priceIsRental)...)
	return !paid, err
}
