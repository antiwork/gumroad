package products

import (
	"context"
	"database/sql"
	"errors"
	"math"
	"strings"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/db"
	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// offerCode is an offer_codes row, with what its scope reads for one product.
type offerCode struct {
	id                                   int64
	code, currencyType, saleLabel        sql.NullString
	amountCents, amountPercentage        sql.NullInt64
	maxPurchaseCount, minimumQuantity    sql.NullInt64
	durationInMonths, minimumAmountCents sql.NullInt64
	universal, existingOnly, newOnly     bool
	validAt, expiresAt, deletedAt        db.NullTime
	flags, tiers                         int64
	// sqlCurrency is whether currency_type matches the product's under the column's collation.
	sqlCurrency                 bool
	hasVariants, hasExclusions  bool
	excludesProduct, forProduct bool
	products                    int64
}

// OfferCode's once_per_cart flag bit.
const offerCodeOncePerCart int64 = 1 << 2

// defaultSaleLabel is OfferCode::DEFAULT_SALE_LABEL.
const defaultSaleLabel = "Sale"

// autoApplyCodes is User#auto_apply_offer_code's scope, for user_id = ?.
const autoApplyCodes = "offer_codes.user_id = ? AND offer_codes.deleted_at IS NULL AND offer_codes.universal = 1" +
	" AND offer_codes.auto_apply = 1 AND offer_codes.new_customers_only = 0"

// loadOfferCode reads the row a condition finds first, nil for none.
func (h *handler) loadOfferCode(ctx context.Context, prod *product, condition string, args ...any) (*offerCode, error) {
	c := &offerCode{}
	var sqlCurrency sql.NullBool
	err := h.c.DB.QueryRowContext(ctx, "SELECT offer_codes.id, offer_codes.code, offer_codes.currency_type, offer_codes.sale_label,"+
		" offer_codes.amount_cents, offer_codes.amount_percentage, offer_codes.max_purchase_count, offer_codes.minimum_quantity,"+
		" offer_codes.duration_in_months, offer_codes.minimum_amount_cents, offer_codes.universal, offer_codes.existing_customers_only,"+
		" offer_codes.new_customers_only, offer_codes.valid_at, offer_codes.expires_at, offer_codes.deleted_at, offer_codes.flags,"+
		" COALESCE(JSON_LENGTH(offer_codes.ownership_duration_tiers), 0), offer_codes.currency_type = ?,"+
		" EXISTS(SELECT 1 FROM offer_codes_variants v WHERE v.offer_code_id = offer_codes.id),"+
		" EXISTS(SELECT 1 FROM offer_codes_excluded_products x WHERE x.offer_code_id = offer_codes.id),"+
		" EXISTS(SELECT 1 FROM offer_codes_excluded_products x WHERE x.offer_code_id = offer_codes.id AND x.product_id = ?),"+
		" EXISTS(SELECT 1 FROM offer_codes_products j WHERE j.offer_code_id = offer_codes.id AND j.product_id = ?),"+
		" (SELECT COUNT(*) FROM offer_codes_products j WHERE j.offer_code_id = offer_codes.id)"+
		" FROM offer_codes WHERE "+condition, append([]any{prod.priceCurrencyType, prod.id, prod.id}, args...)...).
		Scan(&c.id, &c.code, &c.currencyType, &c.saleLabel, &c.amountCents, &c.amountPercentage, &c.maxPurchaseCount,
			&c.minimumQuantity, &c.durationInMonths, &c.minimumAmountCents, &c.universal, &c.existingOnly, &c.newOnly, &c.validAt,
			&c.expiresAt, &c.deletedAt, &c.flags, &c.tiers, &sqlCurrency, &c.hasVariants, &c.hasExclusions, &c.excludesProduct,
			&c.forProduct, &c.products)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	c.sqlCurrency = sqlCurrency.Bool
	return c, err
}

// unportedLookup is a code whose lookups by string this port can't follow: one whose string
// Unicode normalization or the collation would read differently, or whose currency SQL and
// Ruby compare differently.
func (c *offerCode) unportedLookup(prod *product) string {
	switch {
	case !permalinkParam.MatchString(c.code.String):
		return "offer code characters"
	case c.currencyType.Valid && c.sqlCurrency != c.currencyMatches(prod):
		return "offer code currency"
	}
	return ""
}

// unportedDiscount is a code whose evaluation or discount this port doesn't follow.
func (c *offerCode) unportedDiscount() string {
	switch {
	case c.maxPurchaseCount.Valid:
		// quantity_left counts purchases.
		return "offer code limit"
	case c.tiers > 0:
		return "tiered offer code"
	case c.amountCents.Valid == c.amountPercentage.Valid:
		return "offer code amount"
	case c.amountCents.Valid && c.flags&offerCodeOncePerCart != 0:
		return "once-per-cart offer code"
	case c.hasVariants:
		return "offer code variants"
	case c.universal && c.hasExclusions:
		return "offer code exclusions"
	case !c.universal && (c.products != 1 || !c.forProduct):
		return "offer code products"
	}
	return ""
}

// currencyMatches is product.price_currency_type == currency_type.
func (c *offerCode) currencyMatches(prod *product) bool {
	return prod.priceCurrencyType.Valid && c.currencyType.Valid && prod.priceCurrencyType.String == c.currencyType.String
}

// currencyValid is OfferCode#is_currency_valid?.
func (c *offerCode) currencyValid(prod *product) bool {
	return c.amountPercentage.Valid || !c.currencyType.Valid || c.currencyMatches(prod)
}

// applicable is OfferCode#applicable?.
func (c *offerCode) applicable(prod *product) bool {
	if !c.universal {
		return c.forProduct
	}
	return !c.excludesProduct && (!rails.Present(c.currencyType.String) || c.currencyMatches(prod))
}

// inactive is OfferCode#inactive?.
func (c *offerCode) inactive(now time.Time) bool {
	return c.validAt.Valid && c.validAt.Time.After(now) || c.expiresAt.Valid && c.expiresAt.Time.Before(now)
}

// offerDiscount is what BestOfferCodeService#result gives a signed-out visitor with no code
// in the URL, and its sale label.
type offerDiscount struct {
	// listed is whether default_offer_codes is non-empty, which selection_discounts reads.
	listed bool
	// code is the default code that applies, nil for none.
	code  *offerCode
	label any
}

func (h *handler) loadOfferDiscount(ctx context.Context, p *page, prod *product) (*offerDiscount, error) {
	d := &offerDiscount{}
	now := p.Req.Now
	// auto_apply_offer_code_for.
	var auto *offerCode
	if p.hasAutoApplyCode {
		a, err := h.loadOfferCode(ctx, prod, autoApplyCodes+" ORDER BY offer_codes.id ASC LIMIT 1", p.seller.id)
		if err != nil {
			return nil, err
		}
		if a != nil && rails.Present(a.code.String) && a.applicable(prod) {
			auto = a
		}
	}
	var explicit *offerCode
	if prod.defaultOfferCodeID.Valid {
		var err error
		if explicit, err = h.loadOfferCode(ctx, prod, "offer_codes.id = ? LIMIT 1", prod.defaultOfferCodeID.Int64); err != nil {
			return nil, err
		}
	}
	// effective_default_offer_code.
	eff := explicit
	if eff != nil && eff.newOnly {
		eff = nil
	}
	if auto != nil {
		redeemable := eff != nil && !eff.deletedAt.Valid && rails.Present(eff.code.String) && !eff.inactive(now) && !eff.existingOnly &&
			eff.currencyValid(prod)
		if redeemable && eff.maxPurchaseCount.Valid {
			// default_offer_code_uses_left? counts purchases.
			return nil, fallback("offer code limit")
		}
		if !redeemable {
			eff = auto
		}
	}
	var list []*offerCode
	if explicit != nil && explicit.existingOnly && explicit.currencyValid(prod) {
		list = append(list, explicit)
	}
	if eff != nil && eff.currencyValid(prod) && (len(list) == 0 || list[0].id != eff.id) {
		list = append(list, eff)
	}
	d.listed = len(list) > 0
	for _, c := range list {
		if rails.Blank(c.code.String) {
			continue
		}
		valid, err := h.evaluateOfferCode(ctx, prod, c, now)
		if err != nil {
			return nil, err
		}
		if valid {
			d.code = c
			break
		}
	}
	if d.code != nil && auto != nil {
		// sale_label: the winning code is the auto-applied one.
		if !permalinkParam.MatchString(auto.code.String) {
			return nil, fallback("offer code characters")
		}
		if strings.EqualFold(d.code.code.String, auto.code.String) {
			d.label = defaultSaleLabel
			if rails.Present(auto.saleLabel.String) {
				d.label = auto.saleLabel.String
			}
		}
	}
	return d, nil
}

// evaluateOfferCode is BestOfferCodeService#evaluate_code for a default code: whether it
// gives this visitor a discount. Each lookup by its string must find c and only c.
func (h *handler) evaluateOfferCode(ctx context.Context, prod *product, c *offerCode, now time.Time) (bool, error) {
	if reason := c.unportedLookup(prod); reason != "" {
		return false, fallback(reason)
	}
	// evaluate_for_buyer(nil) gives a code for existing customers nothing, whatever its terms.
	if reason := c.unportedDiscount(); reason != "" && !c.existingOnly {
		return false, fallback(reason)
	}
	code := strings.ToLower(c.code.String)
	// find_offer_code: the product's codes, then the seller's universal ones; neither is ordered.
	var id int64
	n, err := h.scanFirst(ctx, []any{&id}, "SELECT offer_codes.id FROM offer_codes INNER JOIN offer_codes_products"+
		" ON offer_codes.id = offer_codes_products.offer_code_id WHERE offer_codes_products.product_id = ?"+
		" AND offer_codes.deleted_at IS NULL AND offer_codes.code = ? LIMIT 2", prod.id, code)
	if err == nil && n == 0 {
		n, err = h.scanFirst(ctx, []any{&id}, "SELECT offer_codes.id FROM offer_codes WHERE offer_codes.user_id = ?"+
			" AND offer_codes.universal = 1 AND (offer_codes.currency_type = ? OR offer_codes.currency_type IS NULL)"+
			" AND offer_codes.deleted_at IS NULL AND NOT EXISTS (SELECT 1 FROM offer_codes_excluded_products x"+
			" WHERE x.offer_code_id = offer_codes.id AND x.product_id = ?) AND offer_codes.code = ? LIMIT 2",
			prod.userID, prod.priceCurrencyType, prod.id, code)
	}
	switch {
	case err != nil:
		return false, err
	case n == 0:
		return false, nil
	case n > 1 || id != c.id:
		return false, fallback("offer code lookup")
	}
	// OfferCodeDiscountComputingService finds the seller's codes by string again.
	n, err = h.scanFirst(ctx, []any{&id}, "SELECT offer_codes.id FROM offer_codes WHERE offer_codes.user_id = ?"+
		" AND offer_codes.code = ? AND offer_codes.deleted_at IS NULL LIMIT 2", prod.userID, code)
	if err != nil {
		return false, err
	}
	if n != 1 || id != c.id {
		return false, fallback("offer code lookup")
	}
	return c.applicable(prod) && c.currencyValid(prod) && !c.existingOnly && !c.inactive(now), nil
}

// resultProps is the discount_code prop: the code that applies and OfferCode#discount.
func (d *offerDiscount) resultProps(prodExternalID string) any {
	c := d.code
	if c == nil {
		return nil
	}
	discount := rails.NewRHash()
	if c.amountCents.Valid {
		discount.Sym("type", "fixed").Sym("cents", c.amountCents.Int64)
	} else {
		discount.Sym("type", "percent").Sym("percents", c.amountPercentage.Int64)
	}
	var productIDs any
	if !c.universal {
		productIDs = []any{prodExternalID}
	}
	discount.Sym("product_ids", productIDs).
		Sym("expires_at", c.expiresAt.OrNil()).
		Sym("minimum_quantity", nullInt(c.minimumQuantity)).
		Sym("duration_in_billing_cycles", nullInt(c.durationInMonths)).
		Sym("minimum_amount_cents", nullInt(c.minimumAmountCents))
	return rails.NewRHash().Sym("valid", true).Sym("code", c.code.String).Sym("discount", discount)
}

// selectionDiscounts is selection_discounts with no code in the URL. With no default code it
// has no options; otherwise each option the buyer can pick, rented or bought, shares the one
// result, since no code here is scoped to options.
func selectionDiscounts(prod *product, v *view, result any) *rails.RHash {
	s := rails.NewRHash().Sym("url_code", nil).Sym("quantity", int64(1)).Sym("recurrence", v.recurrences.defaultRecurrence()).
		Sym("option_id", nil).Sym("price_cents", nil)
	if !v.discount.listed {
		return s.Sym("options", rails.NewRHash()).Sym("rent_options", nil)
	}
	entry := rails.NewRHash().Sym("discount_code", result).Sym("sale_label", v.discount.label)
	quotes := func() *rails.RHash {
		out := rails.NewRHash()
		if len(v.variants.options) == 0 {
			return out.Str("", entry)
		}
		for _, o := range v.variants.options {
			// cart_item prices another option in a closed tier's place.
			if !o.closed {
				out.Str(o.externalID, entry)
			}
		}
		return out
	}
	var rentOptions any
	if v.prices.rental != nil && !prod.rentOnly() {
		rentOptions = quotes()
	}
	return s.Sym("options", quotes()).Sym("rent_options", rentOptions)
}

// discountedCents is discounted_price_cents at quantity 1.
func (d *offerDiscount) discountedCents(price int64) int64 {
	c := d.code
	if c == nil || c.minimumQuantity.Int64 > 1 {
		return price
	}
	if c.amountCents.Valid {
		return max(price-c.amountCents.Int64, 0)
	}
	return price - int64(math.Round(float64(price)*(float64(c.amountPercentage.Int64)/100.0)))
}
