package products

import (
	"database/sql"
	"math/big"
	"regexp"
	"slices"
	"strconv"
	"strings"

	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// LinksController::PRICE_INPUT_MAX_LENGTH and PRICE_INPUT_PATTERN, and
// BasePrice::Shared::MAX_PRICE_CENTS.
const (
	priceInputMaxLength = 64
	maxPriceCents       = 2_147_483_647
)

var priceInput = regexp.MustCompile(`\A[+-]?(?:\d+(?:\.\d*)?|\.\d+)\z`)

// wantedItem is the cart item show's wanted=true sends to checkout.
type wantedItem struct {
	price      int64
	recurrence string
	rental     bool
	// params are show's own writes to params ahead of cart_item, which reach the checkout URL;
	// nil drops the key.
	params map[string]*string
}

// cartParams are the params cart_item reads once show's wanted=true branch has filled them in.
type cartParams struct {
	// option and recurrence are compared with Strings; anything else matches nothing.
	option, recurrence any
	rent               bool
	// price is params[:price] in cents, nil when blank or unreadable, which to_i reads as 0.
	price  *int64
	writes map[string]*string
}

// readCartParams is show's wanted=true writes: params[:option] ||= the id of the option the
// variant names, params[:recurrence] ||= the first recurrence flagged true, and params[:price]
// through price_cents_from_units when present.
func readCartParams(p *page, prod *product, vs *variants) cartParams {
	c := cartParams{option: p.Req.Param("option"), recurrence: p.Req.Param("recurrence"), rent: p.Req.Param("rent") != nil,
		writes: map[string]*string{}}
	if c.option == nil {
		var id *string
		if name, ok := p.Req.Param("variant").(string); ok {
			if o := optionNamed(prod, vs, name); o != nil {
				id, c.option = &o.externalID, o.externalID
			}
		}
		c.writes["option"] = id
	}
	if c.recurrence == nil {
		for _, r := range allRecurrences {
			if p.Req.Param(r.name) == "true" {
				name := r.name
				c.recurrence, c.writes["recurrence"] = name, &name
				break
			}
		}
	}
	if raw := p.Req.Param("price"); rails.Present(raw) {
		// A non-String's to_s never matches the pattern.
		s, _ := raw.(string)
		var written *string
		if cents, ok := priceCentsFromUnits(s, unitScalingFactor(prod.priceCurrencyType.String)); ok {
			c.price = &cents
			w := strconv.FormatInt(cents, 10)
			written = &w
		}
		c.writes["price"] = written
	}
	return c
}

// optionNamed is the first of Link#options whose name is name.
func optionNamed(prod *product, vs *variants, name string) *variantOption {
	for _, o := range vs.options {
		if o.toOptionName(prod) == any(name) {
			return o
		}
	}
	return nil
}

// priceCentsFromUnits is price_cents_from_units: a decimal amount in the product's currency, in
// its minor units, rounded half up; ok is false where Rails returns nil.
func priceCentsFromUnits(s string, scale int64) (int64, bool) {
	if len(s) > priceInputMaxLength || !priceInput.MatchString(s) {
		return 0, false
	}
	sign, digits := "", s
	switch s[0] {
	case '-':
		sign, digits = "-", s[1:]
	case '+':
		digits = s[1:]
	}
	whole, frac, _ := strings.Cut(digits, ".")
	if whole == "" {
		whole = "0"
	}
	r, ok := new(big.Rat).SetString(sign + whole + "." + frac + "0")
	if !ok || r.Sign() < 0 {
		return 0, false
	}
	cents := roundHalfUp(r.Mul(r, new(big.Rat).SetInt64(scale)), 0).Num()
	if !cents.IsInt64() || cents.Int64() > maxPriceCents {
		return 0, false
	}
	return cents.Int64(), true
}

// wantedCartItem is Link#cart_item for show's wanted=true; nil when show renders the page
// instead: a pay-what-you-want product or option without a price that covers it.
func wantedCartItem(p *page, prod *product, v *view) (*wantedItem, error) {
	c := readCartParams(p, prod, v.variants)
	option, item, err := cartItem(p, prod, v, c)
	if err != nil {
		return nil, err
	}
	if optionPWYW(prod, option) && (c.price == nil || *c.price < item.price) {
		return nil, nil
	}
	return item, nil
}

// optionPWYW is whether cart_item takes params[:price]: the product's customizable_price, or the
// Variant's; to_option_for_product's is_pwyw is false.
func optionPWYW(prod *product, option *variantOption) bool {
	return prod.customizablePrice.Bool || option != nil && !option.sku && option.customizablePrice.Bool
}

// cartItem is Link#cart_item for c: the option it picks and the item.
func cartItem(p *page, prod *product, v *view, c cartParams) (*variantOption, *wantedItem, error) {
	var option *variantOption
	if id, ok := c.option.(string); ok {
		if i := slices.IndexFunc(v.variants.options, func(o *variantOption) bool { return o.externalID == id }); i >= 0 {
			option = v.variants.options[i]
		}
	}
	// A closed tier would be added at quantity 0; Variant.find_by_external_id finds no SKU.
	if option != nil && !option.sku && option.closed {
		option = nil
	}
	if option == nil {
		// The first whose to_option quantity_left isn't 0; a coffee product never gets here.
		if i := slices.IndexFunc(v.variants.options, (*variantOption).available); i >= 0 {
			option = v.variants.options[i]
		}
	}
	item := &wantedItem{rental: c.rent && prod.purchaseType.Int64 != purchaseTypeBuyOnly, params: c.writes}
	recurred := prod.is(productIsRecurringBilling) && wantedRecurrence(prod, v, option, c.recurrence, item)
	if !recurred {
		base := v.priceCents
		if item.rental {
			base = v.prices.rental
		}
		if base != nil {
			item.price = *base
		}
	}
	if option != nil {
		item.price += option.priceDifference.Int64
	}
	var asked int64
	if optionPWYW(prod, option) && c.price != nil {
		asked = *c.price
	}
	item.price = max(asked, item.price)
	if pppEnabled(p, prod) && item.price != 0 {
		cur, known := currencies[prod.productCurrency()]
		if !known {
			return nil, nil, fallback("ppp currency")
		}
		item.price = max(item.price, cur.minPrice)
	}
	return option, item, nil
}

// wantedRecurrence is cart_item's recurrence and its price: the buy price at the requested
// recurrence, else at default_price_recurrence, else the shortest, from a tier's own prices
// when it has one. found is false without any.
func wantedRecurrence(prod *product, v *view, option *variantOption, requested any, item *wantedItem) (found bool) {
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
	pick := -1
	if name, ok := requested.(string); ok {
		pick = slices.IndexFunc(recurring, func(r recurringPrice) bool { return r.name == name })
	}
	if duration, _ := prod.subscriptionDurationName(); pick < 0 && hasDefaultRecurrence(v.prices.rows, duration) {
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
	if pick < 0 {
		return false
	}
	item.price, item.recurrence = recurring[pick].cents, recurring[pick].name
	return true
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
		if written, ok := v.wanted.params[key]; ok {
			if written != nil {
				pairs = append(pairs, [2]string{key, *written})
			}
			continue
		}
		value, ok := p.Req.Param(key).(string)
		if !ok {
			// to_query would nest it.
			return "", fallback("wanted params")
		}
		pairs = append(pairs, [2]string{key, value})
	}
	for _, key := range []string{"option", "recurrence"} {
		if _, had := p.Req.Params.Get(key); !had && v.wanted.params[key] != nil {
			pairs = append(pairs, [2]string{key, *v.wanted.params[key]})
		}
	}
	pairs = append(pairs, [2]string{"product", prod.uniquePermalink.String}, [2]string{"rent", strconv.FormatBool(v.wanted.rental)},
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
