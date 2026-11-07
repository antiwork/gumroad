package products

import (
	"context"
	"math"
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

// loadStock reads the bundle and remaining_for_sale_count once, whichever needs them first.
func (h *handler) loadStock(ctx context.Context, p *page, prod *product, v *view) error {
	if v.bundle != nil {
		return nil
	}
	var err error
	if v.bundle, err = h.loadBundle(ctx, p, prod); err != nil {
		return err
	}
	v.quantityRemaining, err = h.remainingForSaleCount(ctx, prod, v.variants, v.bundle.quantityLeft)
	return err
}

// offerChoice is a quote's pick: the code, and whether its result echoes the URL's string.
type offerChoice struct {
	code    *offerCode
	fromURL bool
}

// resultCode is the string the pick's result echoes: the URL's as typed, else the stored one.
func (c offerChoice) resultCode(urlCode string) string {
	if c.fromURL {
		return urlCode
	}
	return c.code.code.String
}

// comparedOffer is the code that applies when more than one could: discount_code_props' pick, or
// for wanted=true the checkout redirect's, and each selection_discounts entry's by entryKey. Each
// weighs the codes valid where it quotes at its own price: an entry, an option, leaves out a code
// whose scope excludes it, and a zero choice is none valid there.
func (h *handler) comparedOffer(p *page, prod *product, v *view, url *offerCode, defaults []*offerCode) (offerChoice, map[string]offerChoice, error) {
	ctx := p.Ctx
	if err := h.loadStock(ctx, p, prod, v); err != nil {
		return offerChoice{}, nil, err
	}
	// comparison_quantity: the quantity, capped by what's left.
	capped := func(q int64, left *int64) int64 {
		if n, ok := v.quantityRemaining.(int64); ok {
			q = min(q, n)
		}
		if left != nil {
			q = min(q, *left)
		}
		return q
	}
	choose := func(q offerQuote, o *variantOption) offerChoice {
		u := url
		if u != nil && u.excludes(o) {
			u = nil
		}
		var here []*offerCode
		for _, c := range defaults {
			if !c.excludes(o) {
				here = append(here, c)
			}
		}
		if u == nil && len(here) == 0 {
			return offerChoice{}
		}
		code, fromURL := q.pick(u, here)
		return offerChoice{code, fromURL}
	}
	if p.wanted {
		// show weighs the codes at the cart item's price unless it renders the page instead.
		c := readCartParams(p, prod, v.variants)
		option, item, err := cartItem(p, prod, v, c)
		if err != nil {
			return offerChoice{}, nil, err
		}
		if !optionPWYW(prod, option) || c.price != nil && *c.price >= item.price {
			return choose(offerQuote{item.price, capped(p.quantity(), nil)}, nil), nil, nil
		}
	}
	duration, known := prod.subscriptionDurationName()
	if prod.is(productIsTieredMembership) && !known {
		// lowest_tier_price would compare the tier prices with a nil duration.
		return offerChoice{}, nil, fallback("offer code comparison")
	}
	minDifference, err := h.lowestVariantDifference(ctx, prod, v.variants)
	if err != nil {
		return offerChoice{}, nil, err
	}
	display, agreed := displayPriceCents(prod, v.variants.tiers, v.prices.rows, duration, minDifference)
	if !agreed {
		return offerChoice{}, nil, fallback("offer code comparison")
	}
	// discount_code_props has no option or price.
	pagePick := choose(offerQuote{display, capped(p.quantity(), nil)}, nil)
	// selection_discounts' options are bought, or rented when that's all the product does; its
	// rent_options are rented.
	sections := []struct{ rentOptions, rent bool }{{false, prod.rentOnly() && v.prices.rental != nil}}
	if v.prices.rental != nil && !prod.rentOnly() {
		sections = append(sections, struct{ rentOptions, rent bool }{true, true})
	}
	options := v.variants.options
	if len(options) == 0 {
		options = []*variantOption{nil}
	}
	entries := map[string]offerChoice{}
	for _, section := range sections {
		for _, o := range options {
			c := cartParams{recurrence: v.recurrences.defaultRecurrence(), rent: section.rent}
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
				return offerChoice{}, nil, err
			}
			entries[entryKey(section.rentOptions, o)] = choose(offerQuote{item.price, capped(max(p.quantity(), 1), left)}, o)
		}
	}
	return pagePick, entries, nil
}
