package products

import (
	"context"
	"database/sql"
	"math/big"
	"strconv"
	"strings"

	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// productCurrency is product.price_currency_type.to_s.downcase.
func (p *product) productCurrency() string { return rails.Downcase(p.priceCurrencyType.String) }

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

// usdCents is get_usd_cents(currency, cents, rate:): BigDecimal(cents) / rate, rounded half up
// (after * 100 for a single-unit currency). Past maxUSDCents BigDecimal's 32-digit quotient
// could round differently, so that's Rails'.
func usdCents(cents int64, rate float64, singleUnit bool) (int64, bool) {
	r, ok := new(big.Rat).SetString(bigDecimalFloat(rate))
	if !ok || r.Sign() <= 0 || cents < 0 {
		return 0, false
	}
	q := new(big.Rat).Quo(new(big.Rat).SetInt64(cents), r)
	if singleUnit {
		q.Mul(q, big.NewRat(100, 1))
	}
	n := roundHalfUp(q, 0).Num()
	if !n.IsInt64() || n.Int64() > maxUSDCents {
		return 0, false
	}
	return n.Int64(), true
}

// maxUSDCents is far past any price; it keeps the quotient's whole part well inside the
// digits BigDecimal computes.
const maxUSDCents = 1e15

// bigDecimalFloat is the decimal BigDecimal takes a Float operand as: its shortest
// round-trip digits, cut (not rounded) to 16 significant digits.
func bigDecimalFloat(f float64) string {
	s := strconv.FormatFloat(f, 'e', -1, 64)
	mantissa, exp, _ := strings.Cut(s, "e")
	digits := strings.Replace(mantissa, ".", "", 1)
	if len(digits) > 16 {
		digits = digits[:16]
	}
	return digits[:1] + "." + digits[1:] + "e" + exp
}
