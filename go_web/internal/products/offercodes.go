package products

import (
	"context"
	"database/sql"
	"math"
	"regexp"
	"strings"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/db"
	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// offerCode is an offer_codes row, with what its scope reads.
type offerCode struct {
	id                                   int64
	code, currencyType, saleLabel        sql.NullString
	amountCents, amountPercentage        sql.NullInt64
	maxPurchaseCount, minimumQuantity    sql.NullInt64
	durationInMonths, minimumAmountCents sql.NullInt64
	universal, existingOnly, newOnly     bool
	validAt, expiresAt, deletedAt        db.NullTime
	flags, tiers                         int64
	hasVariants, excludesProduct         bool
	exclusions, products                 int64
	forProduct                           bool
}

// OfferCode's once_per_cart flag bit.
const offerCodeOncePerCart int64 = 1 << 2

// defaultSaleLabel is OfferCode::DEFAULT_SALE_LABEL.
const defaultSaleLabel = "Sale"

// safeCode is a code whose lookups don't depend on Unicode normalization or the collation.
var safeCode = regexp.MustCompile(`\A[A-Za-z0-9_-]+\z`)

// offerCodes reads the rows a condition finds, with each one's tiers, variants, exclusions and
// products, the last two also for prod.
func (h *handler) offerCodes(ctx context.Context, prod *product, condition string, args ...any) ([]*offerCode, error) {
	rows, err := h.c.DB.QueryContext(ctx, "SELECT offer_codes.id, offer_codes.code, offer_codes.currency_type, offer_codes.sale_label,"+
		" offer_codes.amount_cents, offer_codes.amount_percentage, offer_codes.max_purchase_count, offer_codes.minimum_quantity,"+
		" offer_codes.duration_in_months, offer_codes.minimum_amount_cents, offer_codes.universal, offer_codes.existing_customers_only,"+
		" offer_codes.new_customers_only, offer_codes.valid_at, offer_codes.expires_at, offer_codes.deleted_at, offer_codes.flags,"+
		" COALESCE(JSON_LENGTH(offer_codes.ownership_duration_tiers), 0),"+
		" EXISTS(SELECT 1 FROM offer_codes_variants WHERE offer_codes_variants.offer_code_id = offer_codes.id),"+
		" (SELECT COUNT(*) FROM offer_codes_excluded_products x WHERE x.offer_code_id = offer_codes.id),"+
		" EXISTS(SELECT 1 FROM offer_codes_excluded_products x WHERE x.offer_code_id = offer_codes.id AND x.product_id = ?),"+
		" (SELECT COUNT(*) FROM offer_codes_products j WHERE j.offer_code_id = offer_codes.id),"+
		" EXISTS(SELECT 1 FROM offer_codes_products j WHERE j.offer_code_id = offer_codes.id AND j.product_id = ?)"+
		" FROM offer_codes "+condition, append([]any{prod.id, prod.id}, args...)...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*offerCode
	for rows.Next() {
		c := &offerCode{}
		if err := rows.Scan(&c.id, &c.code, &c.currencyType, &c.saleLabel, &c.amountCents, &c.amountPercentage, &c.maxPurchaseCount,
			&c.minimumQuantity, &c.durationInMonths, &c.minimumAmountCents, &c.universal, &c.existingOnly, &c.newOnly, &c.validAt,
			&c.expiresAt, &c.deletedAt, &c.flags, &c.tiers, &c.hasVariants, &c.exclusions, &c.excludesProduct, &c.products,
			&c.forProduct); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

func (h *handler) offerCode(ctx context.Context, prod *product, condition string, args ...any) (*offerCode, error) {
	codes, err := h.offerCodes(ctx, prod, condition, args...)
	if err != nil || len(codes) == 0 {
		return nil, err
	}
	return codes[0], nil
}

// unported is a code whose evaluation or discount this port doesn't follow.
func (c *offerCode) unported(prod *product) string {
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
	case c.universal && c.exclusions > 0:
		return "offer code exclusions"
	case !c.universal && (c.products != 1 || !c.forProduct):
		return "offer code products"
	case !safeCode.MatchString(c.code.String):
		return "offer code characters"
	case c.currencyType.Valid && (c.currencyType.String == "" ||
		c.currencyType.String != prod.priceCurrencyType.String && strings.EqualFold(c.currencyType.String, prod.priceCurrencyType.String)):
		// SQL compares it under the collation, Ruby with ==.
		return "offer code currency"
	}
	return ""
}

// currencyValid is OfferCode#is_currency_valid?.
func (c *offerCode) currencyValid(prod *product) bool {
	return c.amountPercentage.Valid || !c.currencyType.Valid || prod.priceCurrencyType.Valid && prod.priceCurrencyType.String == c.currencyType.String
}

// applicable is OfferCode#applicable?.
func (c *offerCode) applicable(prod *product) bool {
	if !c.universal {
		return c.forProduct
	}
	if c.excludesProduct {
		return false
	}
	return !rails.Present(c.currencyType.String) || prod.priceCurrencyType.Valid && prod.priceCurrencyType.String == c.currencyType.String
}

// inactive is OfferCode#inactive?.
func (c *offerCode) inactive(now time.Time) bool {
	return c.validAt.Valid && c.validAt.Time.After(now) || c.expiresAt.Valid && c.expiresAt.Time.Before(now)
}

// discountProps is OfferCode#discount for a code unported has passed.
func (c *offerCode) discountProps(prodExternalID string) *rails.RHash {
	d := rails.NewRHash()
	if c.amountCents.Valid {
		d.Sym("type", "fixed").Sym("cents", c.amountCents.Int64)
	} else {
		d.Sym("type", "percent").Sym("percents", c.amountPercentage.Int64)
	}
	var productIDs any
	if !c.universal {
		productIDs = []any{prodExternalID}
	}
	return d.Sym("product_ids", productIDs).
		Sym("expires_at", c.expiresAt.OrNil()).
		Sym("minimum_quantity", nullInt(c.minimumQuantity)).
		Sym("duration_in_billing_cycles", nullInt(c.durationInMonths)).
		Sym("minimum_amount_cents", nullInt(c.minimumAmountCents))
}

// offerDiscount is what BestOfferCodeService#result gives a signed-out visitor with no code
// in the URL, and its sale label.
type offerDiscount struct {
	// listed is whether default_offer_codes is non-empty, which selection_discounts reads.
	listed bool
	// code is the default code that applies, nil for none; result is its discount_code.
	code   *offerCode
	result any
	label  any
}

func (h *handler) loadOfferDiscount(ctx context.Context, p *page, prod *product) (*offerDiscount, error) {
	d := &offerDiscount{}
	now := p.Req.Now
	// auto_apply_offer_code_for: the seller's first alive universal auto-apply code.
	var auto *offerCode
	if p.hasAutoApplyCode {
		a, err := h.offerCode(ctx, prod, "WHERE offer_codes.user_id = ? AND offer_codes.deleted_at IS NULL AND offer_codes.universal = 1"+
			" AND offer_codes.auto_apply = 1 AND offer_codes.new_customers_only = 0 ORDER BY offer_codes.id ASC LIMIT 1", p.seller.id)
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
		if explicit, err = h.offerCode(ctx, prod, "WHERE offer_codes.id = ? LIMIT 1", prod.defaultOfferCodeID.Int64); err != nil {
			return nil, err
		}
	}
	// effective_default_offer_code.
	eff := explicit
	if eff != nil && eff.newOnly {
		eff = nil
	}
	switch {
	case auto == nil:
	case eff == nil:
		eff = auto
	default:
		if eff.maxPurchaseCount.Valid {
			// default_offer_code_uses_left? counts purchases.
			return nil, fallback("offer code limit")
		}
		redeemable := !eff.deletedAt.Valid && rails.Present(eff.code.String) && !eff.inactive(now) && !eff.existingOnly && eff.currencyValid(prod)
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
	if len(list) == 0 {
		return d, nil
	}
	d.listed = true
	for _, c := range list {
		if rails.Blank(c.code.String) {
			continue
		}
		valid, err := h.evaluateOfferCode(ctx, p, prod, c, now)
		if err != nil {
			return nil, err
		}
		if valid {
			d.code = c
			d.result = rails.NewRHash().Sym("valid", true).Sym("code", c.code.String).Sym("discount", c.discountProps(h.c.IDs.Encrypt(prod.id)))
			break
		}
	}
	if d.code != nil && auto != nil {
		// sale_label: the winning code is the auto-applied one.
		if !safeCode.MatchString(auto.code.String) {
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
// gives this visitor a discount. Each lookup must find c and only c.
func (h *handler) evaluateOfferCode(ctx context.Context, p *page, prod *product, c *offerCode, now time.Time) (bool, error) {
	if reason := c.unported(prod); reason != "" {
		return false, fallback(reason)
	}
	if prod.deletedAt.Valid {
		return false, fallback("offer code on a deleted product")
	}
	code := strings.ToLower(c.code.String)
	// find_offer_code: the product's codes, then the seller's universal ones; neither is ordered.
	found, err := h.offerCodes(ctx, prod, "INNER JOIN offer_codes_products ON offer_codes.id = offer_codes_products.offer_code_id"+
		" WHERE offer_codes_products.product_id = ? AND offer_codes.deleted_at IS NULL AND offer_codes.code = ? LIMIT 2", prod.id, code)
	if err != nil {
		return false, err
	}
	if len(found) == 0 {
		if found, err = h.offerCodes(ctx, prod, "WHERE offer_codes.user_id = ? AND offer_codes.universal = 1"+
			" AND (offer_codes.currency_type = ? OR offer_codes.currency_type IS NULL) AND offer_codes.deleted_at IS NULL"+
			" AND NOT EXISTS (SELECT 1 FROM offer_codes_excluded_products WHERE offer_codes_excluded_products.offer_code_id = offer_codes.id"+
			" AND offer_codes_excluded_products.product_id = ?) AND offer_codes.code = ? LIMIT 2",
			prod.userID, prod.priceCurrencyType, prod.id, code); err != nil {
			return false, err
		}
	}
	switch {
	case len(found) == 0:
		return false, nil
	case len(found) > 1 || found[0].id != c.id:
		return false, fallback("offer code lookup")
	}
	// OfferCodeDiscountComputingService finds the seller's codes by string again.
	again, err := h.offerCodes(ctx, prod, "WHERE offer_codes.user_id = ? AND offer_codes.code = ? AND offer_codes.deleted_at IS NULL LIMIT 2",
		p.seller.id, code)
	if err != nil {
		return false, err
	}
	if len(again) != 1 || again[0].id != c.id {
		return false, fallback("offer code lookup")
	}
	// evaluate_for_buyer(nil) gives nothing to a code for existing customers.
	return c.applicable(prod) && c.currencyValid(prod) && !c.existingOnly && !c.inactive(now), nil
}

// selectionDiscounts is selection_discounts with no code in the URL. With no default code it
// has no options; otherwise each option the buyer can pick, rented or bought, shares the one
// result, since no code here is scoped to options.
func (h *handler) selectionDiscounts(prod *product, v *view) *rails.RHash {
	s := rails.NewRHash().Sym("url_code", nil).Sym("quantity", int64(1)).Sym("recurrence", v.recurrences.defaultRecurrence()).
		Sym("option_id", nil).Sym("price_cents", nil)
	if !v.discount.listed {
		return s.Sym("options", rails.NewRHash()).Sym("rent_options", nil)
	}
	quotes := func() *rails.RHash {
		out := rails.NewRHash()
		entry := rails.NewRHash().Sym("discount_code", v.discount.result).Sym("sale_label", v.discount.label)
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
