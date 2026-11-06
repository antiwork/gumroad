package products

import (
	"strconv"

	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// wantedRendersPage is show's wanted=true rendering the page instead: a pay-what-you-want
// product with no price param, which is declined.
func wantedRendersPage(prod *product) bool { return prod.customizablePrice.Bool }

// wantedCheckout is the checkout URL show's wanted=true branch redirects to. The option, variant,
// rent, price, quantity and recurrence params its cart item reads are declined.
func (h *handler) wantedCheckout(p *page, prod *product, v *view) (string, error) {
	if len(v.variants.options) > 0 || prod.is(productIsRecurringBilling) || prod.is(productIsTieredMembership) {
		// cart_item picks an option or a recurrence.
		return "", fallback("wanted cart item")
	}
	var price int64
	if v.priceCents != nil {
		price = max(*v.priceCents, 0)
	}
	if pppEnabled(p, prod) && price != 0 {
		cur, known := currencies[prod.productCurrency()]
		if !known {
			return "", fallback("ppp currency")
		}
		price = max(price, cur.minPrice)
	}

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
		[2]string{"price", strconv.FormatInt(price, 10)})
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
