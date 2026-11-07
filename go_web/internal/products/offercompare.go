package products

import (
	"math"
	"slices"
)

// offerQuote is a selection BestOfferCodeService weighs codes at: comparison_price_cents and
// comparison_quantity.
type offerQuote struct{ price, quantity int64 }

// met is met_discount_conditions?.
func (q offerQuote) met(c *offerCode) bool {
	return q.quantity >= c.minimumQuantity.Int64 && q.price*q.quantity >= c.minimumAmountCents.Int64
}

// amount is comparison_amount: amount_off_from_discount where the code's conditions are met.
func (q offerQuote) amount(c *offerCode) int64 {
	switch {
	case !q.met(c):
		return 0
	case c.amountCents.Valid && c.oncePerCart():
		return min(c.amountCents.Int64, q.price*q.quantity)
	case c.amountCents.Valid:
		return min(c.amountCents.Int64, q.price) * q.quantity
	}
	return int64(math.Round(float64(q.price*c.amountPercentage.Int64)/100)) * q.quantity
}

// pick is BestOfferCodeService#result among the codes that apply: the best default, a later one
// only when it takes more off, then the URL's against it, which wins only by taking more off
// or when the default's conditions aren't met. fromURL is whether the URL's wins.
func (q offerQuote) pick(url *offerCode, defaults []*offerCode) (code *offerCode, fromURL bool) {
	var best *offerCode
	for _, c := range defaults {
		if best == nil || q.amount(c) > q.amount(best) {
			best = c
		}
	}
	switch {
	case best == nil:
		return url, true
	case url == nil:
		return best, false
	case !q.met(best):
		return url, true
	case !q.met(url):
		return best, false
	case q.amount(url) > q.amount(best):
		return url, true
	}
	return best, false
}

// comparedOffer is the code that applies when more than one could: the page's quote and each of
// selection_discounts' must agree on it, as this port renders one result for every option.
func (h *handler) comparedOffer(p *page, prod *product, v *view, url *offerCode, defaults []*offerCode) (*offerCode, bool, error) {
	// An option-scoped code's validity, and a cart's price, differ per option; checkout's
	// redirect weighs the cart's price.
	if p.wanted || url != nil && url.hasVariants || slices.ContainsFunc(defaults, func(c *offerCode) bool { return c.hasVariants }) {
		return nil, false, fallback("offer code comparison")
	}
	duration, known := prod.subscriptionDurationName()
	if prod.is(productIsTieredMembership) && !known {
		// lowest_tier_price would compare the tier prices with a nil duration.
		return nil, false, fallback("offer code comparison")
	}
	ctx := p.Ctx
	minDifference, err := h.lowestVariantDifference(ctx, prod, v.variants)
	if err != nil {
		return nil, false, err
	}
	display, agreed := displayPriceCents(prod, v.variants.tiers, v.prices.rows, duration, minDifference)
	if !agreed {
		return nil, false, fallback("offer code comparison")
	}
	bundle, err := h.loadBundle(ctx, p, prod)
	if err != nil {
		return nil, false, err
	}
	remaining, err := h.remainingForSaleCount(ctx, prod, v.variants, bundle.quantityLeft)
	if err != nil {
		return nil, false, err
	}
	// comparison_quantity: the quantity, capped by what's left.
	capped := func(q int64, left *int64) int64 {
		if n, ok := remaining.(int64); ok {
			q = min(q, n)
		}
		if left != nil {
			q = min(q, *left)
		}
		return q
	}
	// discount_code_props has no option or price.
	quotes := []offerQuote{{display, capped(p.quantity(), nil)}}
	// selection_discounts: each option, bought (or rented when that's all the product does),
	// then rented too when it also sells.
	rents := []bool{prod.rentOnly() && v.prices.rental != nil}
	if v.prices.rental != nil && !prod.rentOnly() {
		rents = append(rents, true)
	}
	options := v.variants.options
	if len(options) == 0 {
		options = []*variantOption{nil}
	}
	for _, rent := range rents {
		for _, o := range options {
			c := cartParams{recurrence: v.recurrences.defaultRecurrence(), rent: rent}
			var left *int64
			if o != nil {
				if o.closed {
					// cart_item prices another option in a closed tier's place, and that entry is skipped.
					continue
				}
				c.option, left = o.externalID, o.quantityLeft()
			}
			_, item, err := cartItem(p, prod, v, c)
			if err != nil {
				return nil, false, err
			}
			quotes = append(quotes, offerQuote{item.price, capped(max(p.quantity(), 1), left)})
		}
	}
	var code *offerCode
	var fromURL bool
	for i, q := range quotes {
		c, u := q.pick(url, defaults)
		if i > 0 && (c != code || u != fromURL) {
			return nil, false, fallback("offer code comparison")
		}
		code, fromURL = c, u
	}
	return code, fromURL, nil
}
