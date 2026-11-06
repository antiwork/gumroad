package products

import (
	"context"
	"database/sql"

	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// productCurrency is product.price_currency_type.to_s.downcase.
func (p *product) productCurrency() string { return rails.Downcase(p.priceCurrencyType.String) }

// checkCurrencyDisplay is the part of buyer_currency_display_props this port renders: the
// default display, when the seller hasn't opted in or the buyer's currency is the product's.
// A local price goes to Rails, whose settleability checks it leaves out.
func (h *handler) checkCurrencyDisplay(ctx context.Context, p *page, prod *product, v *view) error {
	if raw, ok := v.sellerJSON.present("disable_buyer_local_currency"); ok {
		if disabled := rails.BooleanCast(raw); disabled != nil && *disabled {
			return nil
		}
	}
	on, err := h.flag(ctx, "buyer_local_currency", p.seller.id)
	if err != nil || !on {
		return err
	}
	buyer := buyerCurrencyPreference(p)
	if buyer == nil {
		buyer = v.detectedCurrency
	}
	if buyer != nil && *buyer != prod.productCurrency() {
		return fallback("buyer local currency")
	}
	return nil
}

// buyerCurrencyPreference is buyer_currency_preference: the currency cookie the footer
// selector writes; prepare has left a ?currency= param to Rails.
func buyerCurrencyPreference(p *page) *string {
	raw, ok := p.Req.Cookie("gumroad_buyer_currency")
	if !ok || rails.Blank(raw) {
		return nil
	}
	code := rails.Downcase(raw)
	if _, ok := currencies[code]; !ok {
		return nil
	}
	return &code
}

// checkPPP leaves ppp_details to Rails whenever it would be a discount.
func (h *handler) checkPPP(ctx context.Context, p *page, prod *product, v *view) error {
	if prod.is(productPPPDisabled) || !p.seller.is(userPPPEnabled) || v.geo == nil {
		return nil
	}
	minFactor := 0.0
	if p.seller.pppLimit.Valid && p.seller.pppLimit.Int64 != 0 {
		minFactor = 1 - float64(p.seller.pppLimit.Int64)/100.0
	}
	factor, ok := pppFactor(ctx, h.c.Page.Redis, v.geo.CountryCode)
	if !ok {
		return fallback("ppp factor")
	}
	if max(factor, minFactor) < 1 {
		return fallback("ppp")
	}
	return nil
}

// remainingForSaleCount is Link#remaining_for_sale_count without variants or bundles, its
// inventory read afresh.
func (h *handler) remainingForSaleCount(ctx context.Context, prod *product) (any, error) {
	if !prod.maxPurchaseCount.Valid {
		return nil, nil
	}
	var sold sql.NullInt64
	if err := h.c.DB.QueryRowContext(ctx, "SELECT `links`.`sales_count_for_inventory_cache` FROM `links` WHERE `links`.`id` = ? LIMIT 1", prod.id).
		Scan(&sold); err != nil {
		return nil, err
	}
	return max(prod.maxPurchaseCount.Int64-sold.Int64, 0), nil
}

// hasThirdPartyAnalytics is has_third_party_analytics?("product").
func (h *handler) hasThirdPartyAnalytics(ctx context.Context, prod *product) (bool, error) {
	found, err := h.exists(ctx, "SELECT 1 FROM third_party_analytics WHERE third_party_analytics.link_id = ?"+
		" AND third_party_analytics.deleted_at IS NULL AND third_party_analytics.location IN ('product', 'all') LIMIT 1", prod.id)
	if err != nil || found {
		return found, err
	}
	return h.exists(ctx, "SELECT 1 FROM third_party_analytics WHERE third_party_analytics.user_id = ? AND (link_id is null)"+
		" AND third_party_analytics.deleted_at IS NULL AND third_party_analytics.location IN ('product', 'all') LIMIT 1", prod.userID)
}
