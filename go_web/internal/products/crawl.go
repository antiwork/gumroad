package products

import (
	"database/sql"
	"errors"
	"strings"

	"github.com/antiwork/gumroad/go_web/internal/description"
	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/web"
)

// crawlFallback is set_product_page_crawl_fallback rendered through the _seo_product_fallback
// partial, "" where show skips it.
func (h *handler) crawlFallback(p *page, prod *product, v *view) (string, error) {
	if inertiaVisit(p) || p.iframe || p.layout == productLayoutDiscover || prod.draft.Bool || !prod.alive() {
		return "", nil
	}
	html, _ := v.descriptionHTML.(string)
	text, err := description.CrawlText(html)
	if errors.Is(err, description.ErrUnported) {
		return "", fallback("crawl fallback description")
	}
	if err != nil {
		return "", err
	}
	price, err := h.crawlPrice(p, prod, v)
	if err != nil {
		return "", err
	}
	var b strings.Builder
	b.WriteString("<noscript>\n  <article>\n    <h1>")
	web.WriteHTMLEscaped(&b, prod.name)
	b.WriteString("</h1>\n")
	if seller := nameOrUsername(p.seller); rails.Present(seller) {
		b.WriteString("      <p>by ")
		web.WriteHTMLEscaped(&b, seller)
		b.WriteString("</p>\n")
	}
	if rails.Present(price) {
		b.WriteString("      <p>")
		web.WriteHTMLEscaped(&b, price)
		b.WriteString("</p>\n")
	}
	// html_escape leaves no "</noscript" for the partial's gsub to guard against.
	b.WriteString("    " + description.Paragraphs(web.HTMLEscape(text)) + "\n  </article>\n</noscript>\n")
	return b.String(), nil
}

// crawlPrice is price_formatted_verbose(for_default_duration: true, discounted: true), "" for a
// product without a currency.
func (h *handler) crawlPrice(p *page, prod *product, v *view) (string, error) {
	if rails.Blank(prod.priceCurrencyType.String) {
		return "", nil
	}
	duration, ok := prod.subscriptionDurationName()
	tiered := prod.is(productIsTieredMembership)
	if !ok || tiered && duration == "" {
		// lowest_tier_price would match the tier prices without a recurrence.
		return "", fallback("crawl fallback subscription duration")
	}
	// A tiered membership's price and code coverage leave the variant differences out.
	var minDifference sql.NullInt64
	var err error
	if !tiered {
		if minDifference, err = h.variantFloor(p.Ctx, prod, v); err != nil {
			return "", err
		}
	}
	base, agreed := displayPriceCents(prod, v.variants.tiers, v.prices.rows, duration, minDifference)
	if !agreed {
		return "", fallback("crawl fallback price")
	}
	price := base
	if code := v.discount.effective; code != nil {
		if tiered && code.hasVariants {
			// lowest_priced_tier_ids weighs the tiers' prices.
			return "", fallback("crawl fallback offer code tiers")
		}
		if price, err = h.discountedPriceCents(p, prod, code, minDifference, base); err != nil {
			return "", err
		}
	}
	formatted, ok := displayPrice(price, prod.priceCurrencyType.String)
	if !ok {
		return "", fallback("crawl fallback currency")
	}
	if customizablePriceIndicator(prod, v.variants) {
		formatted += "+"
	}
	if prod.is(productIsRecurringBilling) {
		label, ok := recurrenceLabel(duration, prod.durationInMonths)
		if !ok {
			return "", fallback("crawl fallback duration in months")
		}
		formatted += " " + label
	}
	return formatted, nil
}
