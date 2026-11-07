package products

import (
	"database/sql"
	"strings"

	"github.com/antiwork/gumroad/go_web/internal/db"
	"github.com/antiwork/gumroad/go_web/internal/inertia"
	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// PageMeta::Product's DEMO_PLAYER_CARD_WIDTH and DEMO_PLAYER_CARD_HEIGHT.
const (
	demoPlayerCardWidth  = 640
	demoPlayerCardHeight = 480
)

// ContentModeration::GumroadImpersonation::PROVEN_ACCOUNT_AGE, in days.
const provenAccountAgeDays = 30

// metaProperty is a property meta tag's name and content.
type metaProperty struct {
	property string
	content  inertia.Attr
}

// demoPlayerCard is demo_player_card_meta: the X player card for the product's public demo, nil
// without one.
func (h *handler) demoPlayerCard(p *page, prod *product, v *view, image string) ([]metaProperty, error) {
	if !rails.Present(image) {
		return nil, nil
	}
	// demo? reads this flag again, which Flipper's memoizer answers the same.
	if on, err := h.pageFlag(p, "product_build_demo"); err != nil || !on {
		return nil, err
	}
	if demo, err := h.hasDemo(p, prod, v); err != nil || !demo {
		return nil, err
	}
	content := func(s string) inertia.Attr { return inertia.Attr{Key: "content", Value: s} }
	width, _ := numberAttr(int64(demoPlayerCardWidth))
	height, _ := numberAttr(int64(demoPlayerCardHeight))
	return []metaProperty{
		{"twitter:card", content("player")},
		{"twitter:image", content(image)},
		{"twitter:player", content(h.c.Env.Protocol + "://" + h.c.Env.Domain + "/demo/" + h.c.IDs.Encrypt(prod.id))},
		{"twitter:player:width", width},
		{"twitter:player:height", height},
	}, nil
}

// hasDemo is ProductBuild.demo_for(product) being present.
func (h *handler) hasDemo(p *page, prod *product, v *view) (bool, error) {
	type build struct {
		live, siteReady, demoSelected bool
	}
	// min_by keeps the first build with the least key: the first demo-selected one, else the first.
	var found *build
	err := scanNamed(p.Ctx, h.c.DB, func(cols map[string]any) func() {
		var status string
		var unpacked, selected db.NullTime
		cols["status"], cols["site_unpacked_at"], cols["demo_selected_at"] = &status, &unpacked, &selected
		return func() {
			if found == nil || selected.Valid && !found.demoSelected {
				found = &build{live: status == "live", siteReady: unpacked.Valid, demoSelected: selected.Valid}
			}
		}
	}, "SELECT `product_builds`.* FROM `product_builds` WHERE `product_builds`.`product_id` = ?"+
		" AND (`product_builds`.`demo_selected_at` IS NOT NULL OR `product_builds`.`status` = 'live')"+
		" ORDER BY `product_builds`.`number` ASC", prod.id)
	if err != nil || found == nil {
		return false, err
	}
	if on, err := h.pageFlag(p, "product_build_player"); err != nil || !on {
		return false, err
	}
	if !found.siteReady || !onSale(prod, p.seller) {
		return false, nil
	}
	if unproven, err := h.unprovenSeller(p); err != nil || unproven {
		return false, err
	}
	if found.demoSelected {
		// !purchased_version?
		if !found.live {
			return true, nil
		}
		return h.freeProduct(p, prod, v)
	}
	// SQL's status = 'live' follows the collation; live? compares bytes.
	if !found.live {
		return false, nil
	}
	if free, err := h.freeProduct(p, prod, v); err != nil || !free {
		return false, err
	}
	// A zero demo_selected_at is nil to Rails but not NULL to MySQL, so the scan doesn't answer this.
	selected, err := h.exists(p.Ctx, "SELECT 1 AS one FROM `product_builds` WHERE `product_builds`.`product_id` = ?"+
		" AND `product_builds`.`demo_selected_at` IS NOT NULL LIMIT 1", prod.id)
	return !selected, err
}

// onSale is ProductBuild#on_sale?, for the product's seller.
func onSale(prod *product, seller *user) bool {
	return prod.published() && !prod.bannedAt.Valid && !prod.is(productIsInPreorderState) && !seller.deletedAt.Valid && !seller.suspended()
}

// unprovenSeller is ContentModeration::GumroadImpersonation.unproven_seller? for the seller.
func (h *handler) unprovenSeller(p *page) (bool, error) {
	var createdAt, confirmedAt db.NullTime
	var email sql.NullString
	if err := h.c.DB.QueryRowContext(p.Ctx, "SELECT users.created_at, users.confirmed_at, users.email FROM users WHERE users.id = ? LIMIT 1",
		p.seller.id).Scan(&createdAt, &confirmedAt, &email); err != nil {
		return false, err
	}
	// gumroad_staff?
	if confirmedAt.Valid && strings.HasSuffix(rails.Downcase(email.String), "@gumroad.com") {
		return false, nil
	}
	// 30.days.ago, in the app's UTC zone.
	if createdAt.Valid && !createdAt.Time.After(p.Req.Now.UTC().AddDate(0, 0, -provenAccountAgeDays)) {
		return false, nil
	}
	paid, err := h.exists(p.Ctx, "SELECT 1 AS one FROM `purchases` WHERE `purchases`.`seller_id` = ?"+
		" AND `purchases`.`purchase_state` = 'successful' AND (purchases.price_cents > 0)"+
		" AND (stripe_refunded is null OR stripe_refunded = 0) LIMIT 1", p.seller.id)
	return !paid, err
}

// aliveVariantsFrom is Link#alive_variants' FROM and WHERE.
const aliveVariantsFrom = " FROM `base_variants` INNER JOIN `variant_categories` ON `base_variants`.`variant_category_id` = `variant_categories`.`id`" +
	" WHERE `base_variants`.`type` = 'Variant' AND `variant_categories`.`link_id` = ? AND `variant_categories`.`deleted_at` IS NULL" +
	" AND `base_variants`.`deleted_at` IS NULL"

// freeProduct is ProductBuild.free_product?, whose price_cents is the buy price once the product
// isn't rent-only.
func (h *handler) freeProduct(p *page, prod *product, v *view) (bool, error) {
	if prod.rentOnly() || prod.is(productIsRecurringBilling) || v.prices.buy == nil || *v.prices.buy != 0 {
		return false, nil
	}
	if paid, err := h.exists(p.Ctx, "SELECT 1 AS one"+aliveVariantsFrom+" AND (price_difference_cents > 0) LIMIT 1", prod.id); err != nil || paid {
		return false, err
	}
	paid, err := h.exists(p.Ctx, "SELECT 1 AS one FROM `prices` WHERE `prices`.`deleted_at` IS NULL AND ((`prices`.`flags` & 1 = 0))"+
		" AND `prices`.`variant_id` IN (SELECT `base_variants`.`id`"+aliveVariantsFrom+") AND (price_cents > 0) LIMIT 1", prod.id)
	return !paid, err
}
