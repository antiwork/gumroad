package products

import (
	"context"
	"database/sql"
	"math"
	"math/big"
	"strconv"
	"strings"

	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// productCurrency is product.price_currency_type.to_s.downcase.
func (p *product) productCurrency() string { return rails.Downcase(p.priceCurrencyType.String) }

// buyerCurrencyPreference is buyer_currency_preference: params[:currency].presence, else the
// currency cookie the footer selector writes. declinedParams leaves a non-String param to Rails.
func buyerCurrencyPreference(p *page) *string {
	raw, _ := p.Req.Param("currency").(string)
	if rails.Blank(raw) {
		var ok bool
		if raw, ok = p.Req.Cookie("gumroad_buyer_currency"); !ok || rails.Blank(raw) {
			return nil
		}
	}
	code := rails.Downcase(raw)
	if _, ok := currencies[code]; !ok {
		return nil
	}
	return &code
}

// pppEnabled is Link#purchasing_power_parity_enabled?.
func pppEnabled(p *page, prod *product) bool {
	return !prod.is(productPPPDisabled) && p.seller.is(userPPPEnabled)
}

// loadPPP is Link#ppp_details, and returns ProductProps#ppp_price_cents.
func (h *handler) loadPPP(ctx context.Context, p *page, prod *product, v *view) (*int64, error) {
	if !pppEnabled(p, prod) || v.geo == nil {
		return nil, nil
	}
	minFactor := 0.0
	if p.seller.pppLimit.Valid && p.seller.pppLimit.Int64 != 0 {
		minFactor = 1 - float64(p.seller.pppLimit.Int64)/100.0
	}
	factor, ok := pppFactor(ctx, h.c.Page.Redis, v.geo.CountryCode)
	if !ok || math.Signbit(factor) {
		// [factor, min_ppp_factor].max can keep a negative factor, or a -0.0, typed as Ruby has it.
		return nil, fallback("ppp factor")
	}
	if factor = max(factor, minFactor); factor >= 1 {
		return nil, nil
	}
	cur, ok := currencies[prod.productCurrency()]
	if !ok {
		return nil, fallback("ppp currency")
	}
	v.ppp = &pppDetails{country: v.geo.CountryName, factor: factor, minimumPrice: cur.minPrice}
	price := v.priceCents
	if price == nil || *price == 0 {
		return nil, nil
	}
	// From the undiscounted price. Float#round rounds half away from zero, as math.Round does.
	pppPrice := max(int64(math.Round(factor*float64(*price))), cur.minPrice)
	return &pppPrice, nil
}

// pppDetails is Link#ppp_details when the factor is below 1.
type pppDetails struct {
	country      *string
	factor       float64
	minimumPrice int64
}

func (d *pppDetails) props() any {
	if d == nil {
		return nil
	}
	return rails.NewRHash().Sym("country", nullableString(d.country)).Sym("factor", d.factor).Sym("minimum_price", d.minimumPrice)
}

// remainingForSaleCount is Link#remaining_for_sale_count, its inventory read afresh.
// bundleLeft is the bundle products' minimum, for a bundle.
func (h *handler) remainingForSaleCount(ctx context.Context, prod *product, vs *variants, bundleLeft *int64) (any, error) {
	if !vs.available() {
		return int64(0), nil
	}
	if len(vs.tiers) == 1 {
		// A lone tier's own inventory, closed or not.
		return intOrNil(vs.tiers[0].quantityLeft()), nil
	}
	left := bundleLeft
	if prod.maxPurchaseCount.Valid {
		var sold sql.NullInt64
		if err := h.c.DB.QueryRowContext(ctx, "SELECT `links`.`sales_count_for_inventory_cache` FROM `links` WHERE `links`.`id` = ? LIMIT 1", prod.id).
			Scan(&sold); err != nil {
			return nil, err
		}
		left = lowerOf(left, quantityLeft(prod.maxPurchaseCount, sold))
	}
	return intOrNil(left), nil
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
