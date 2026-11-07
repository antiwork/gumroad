package products

import (
	"database/sql"
	"slices"
	"strconv"

	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// wantedItem is the cart item show's wanted=true sends to checkout.
type wantedItem struct {
	price      int64
	recurrence string
}

// wantedCartItem is Link#cart_item for show's wanted=true, whose option, variant, rent, price
// and recurrence params are declined; nil when show renders the page instead, for a
// pay-what-you-want product or option.
func wantedCartItem(p *page, prod *product, v *view) (*wantedItem, error) {
	// The first option whose to_option quantity_left isn't 0; a coffee product never gets here.
	var option *variantOption
	if i := slices.IndexFunc(v.variants.options, (*variantOption).available); i >= 0 {
		option = v.variants.options[i]
	}
	item := &wantedItem{}
	if v.priceCents != nil {
		item.price = *v.priceCents
	}
	if prod.is(productIsRecurringBilling) {
		wantedRecurrence(prod, v, option, item)
	}
	if option != nil {
		item.price += option.priceDifference.Int64
	}
	item.price = max(item.price, 0)
	if pppEnabled(p, prod) && item.price != 0 {
		cur, known := currencies[prod.productCurrency()]
		if !known {
			return nil, fallback("ppp currency")
		}
		item.price = max(item.price, cur.minPrice)
	}
	// to_option_for_product's is_pwyw is false.
	if prod.customizablePrice.Bool || option != nil && !option.sku && option.customizablePrice.Bool {
		return nil, nil
	}
	return item, nil
}

// wantedRecurrence is cart_item's recurrence and its price: the buy price at
// default_price_recurrence, else the shortest, from a tier's own prices when it has one.
func wantedRecurrence(prod *product, v *view, option *variantOption, item *wantedItem) {
	type recurringPrice struct {
		cents  int64
		name   string
		months int
	}
	var recurring []recurringPrice
	add := func(cents int64, name sql.NullString) {
		if r, ok := recurrenceNamed(name.String); ok {
			recurring = append(recurring, recurringPrice{cents, r.name, r.months})
		}
	}
	// Variant.find_by_external_id finds no SKU, and a tiered membership has none here.
	if prod.is(productIsTieredMembership) && option != nil {
		for _, vp := range option.buyPrices {
			add(vp.cents, vp.recurrence)
		}
	} else {
		for _, r := range v.prices.rows {
			if !r.isRental() {
				add(r.cents, r.recurrence)
			}
		}
	}
	duration, _ := prod.subscriptionDurationName()
	pick := -1
	if hasDefaultRecurrence(v.prices.rows, duration) {
		pick = slices.IndexFunc(recurring, func(r recurringPrice) bool { return r.name == duration })
	}
	if pick < 0 {
		// min_by keeps the first of a tie.
		for i, r := range recurring {
			if pick < 0 || r.months < recurring[pick].months {
				pick = i
			}
		}
	}
	if pick >= 0 {
		item.price, item.recurrence = recurring[pick].cents, recurring[pick].name
	}
}

// wantedCheckout is the checkout URL show's wanted=true branch redirects to.
func (h *handler) wantedCheckout(p *page, prod *product, v *view) (string, error) {
	// The request's String keys and checkout_url's own Symbol ones are different keys, so both
	// reach the query.
	var pairs [][2]string
	for _, key := range p.Req.Params.Keys() {
		if key == "code" || key == "offer_code" {
			continue
		}
		value, ok := p.Req.Param(key).(string)
		if !ok {
			// to_query would nest it.
			return "", fallback("wanted params")
		}
		pairs = append(pairs, [2]string{key, value})
	}
	pairs = append(pairs, [2]string{"product", prod.uniquePermalink.String}, [2]string{"rent", "false"},
		[2]string{"price", strconv.FormatInt(v.wanted.price, 10)})
	if v.wanted.recurrence != "" {
		pairs = append(pairs, [2]string{"recurrence", v.wanted.recurrence})
	}
	if d := v.discount; d != nil && d.code != nil {
		pairs = append(pairs, [2]string{"code", d.resultCode})
	}
	var referrer any
	if r := p.Req.Referrer(); r != nil {
		referrer = *r
	}
	// params[:affiliate_id] || params[:a] and params[:referrer] || request.referrer; nil drops out.
	for _, pair := range []struct {
		key    string
		values []any
	}{{"affiliate_id", []any{p.Req.Param("affiliate_id"), p.Req.Param("a")}}, {"referrer", []any{p.Req.Param("referrer"), referrer}}} {
		for _, value := range pair.values {
			if value == nil {
				continue
			}
			s, ok := value.(string)
			if !ok {
				return "", fallback("wanted params")
			}
			pairs = append(pairs, [2]string{pair.key, s})
			break
		}
	}
	return h.c.Env.Protocol + "://" + h.c.Env.Domain + "/checkout?" + rails.ToQuery(pairs...), nil
}
