package downloads

import (
	"database/sql"
	"encoding/json"
	"strings"

	"github.com/antiwork/gumroad/go_web/internal/pages"
	"github.com/antiwork/gumroad/go_web/internal/products"
	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// BuyerCurrency is buyer_currency_display_props(product:, price_cents:, ip:) with no preferred
// currency.
type BuyerCurrency interface {
	Display(v *pages.Visit, productID, price int64, ip string) (*rails.RHash, error)
}

// userSkipFreeSaleAnalytics is User 2 => :skip_free_sale_analytics.
const userSkipFreeSaleAnalytics = 1 << 1

// zeroDecimalCurrencies is StripeChargeProcessor::ZERO_DECIMAL_CURRENCIES. Every other
// CURRENCY_CHOICES code charges in hundredths.
var zeroDecimalCurrencies = map[string]bool{"bif": true, "clp": true, "djf": true, "gnf": true, "jpy": true, "kmf": true,
	"krw": true, "mga": true, "pyg": true, "rwf": true, "ugx": true, "vnd": true, "vuv": true, "xaf": true, "xof": true, "xpf": true}

// sellerAnalytics is PurchaseSellerAnalyticsPresenter#props: nil unless the product's user has
// a Google Analytics, Facebook pixel or TikTok pixel id, where "" counts.
func (h *handler) sellerAnalytics(p *page, d *pageData, ga, pixel sql.NullString, tiktok any) (any, error) {
	// attr_json_data_accessor reads a blank value as nil.
	if !rails.Present(tiktok) {
		tiktok = nil
	}
	if !ga.Valid && !pixel.Valid && tiktok == nil {
		return nil, nil
	}
	switch tiktok.(type) {
	case nil, string, bool, json.Number:
	default:
		return nil, fallback("seller json_data")
	}
	if h.c.Pages.BuyerCurrency == nil {
		return nil, fallback("seller analytics")
	}
	pu := p.purchase
	var (
		displayedCents, taxCents                             sql.NullInt64
		currency, rate, productCurrency, presentmentCurrency sql.NullString
		ownerFlags, presentmentTotal                         sql.NullInt64
		presentment                                          bool
	)
	if err := h.c.DB.QueryRowContext(p.Ctx, `SELECT purchases.displayed_price_cents, purchases.displayed_price_currency_type,
		purchases.tax_cents, purchases.rate_converted_to_usd, links.price_currency_type, owner.flags,
		purchase_presentments.id IS NOT NULL, purchase_presentments.presentment_currency, purchase_presentments.presentment_total_cents
		FROM purchases JOIN links ON links.id = purchases.link_id LEFT JOIN users owner ON owner.id = links.user_id
		LEFT JOIN purchase_presentments ON purchase_presentments.purchase_id = purchases.id
		WHERE purchases.id = ? LIMIT 1`, pu.id).
		Scan(&displayedCents, &currency, &taxCents, &rate, &productCurrency, &ownerFlags, &presentment, &presentmentCurrency, &presentmentTotal); err != nil {
		return nil, err
	}
	// Money.new raises on a nil amount or a currency it doesn't know, as does nil.to_sym.
	if !displayedCents.Valid || !currency.Valid || !products.CurrencyChoice(currency.String) {
		return nil, fallback("displayed price")
	}
	// seller_taxes_in_purchase_currency converts tax_cents through the purchase's rate, or
	// get_rate's for the product's currency, which only a code outside CURRENCY_CHOICES can fail;
	// zero converts to zero and formats as "0" in every CURRENCY_CHOICES currency.
	if taxCents.Int64 != 0 || productCurrency.String != "usd" && !rails.Present(rate.String) && !products.CurrencyChoice(productCurrency.String) {
		return nil, fallback("seller tax")
	}
	var ip string
	if pu.ipAddress != nil {
		ip = *pu.ipAddress
	}
	display, err := h.c.Pages.BuyerCurrency.Display(p.Visit, d.productID, displayedCents.Int64, ip)
	if err != nil {
		return nil, err
	}
	event := rails.NewRHash().
		Sym("permalink", nullableString(d.uniquePermalink)).
		Sym("purchase_external_id", h.c.IDs.Encrypt(pu.id)).
		Sym("product_name", nullableString(d.productName)).
		Sym("value", displayedCents.Int64).
		Sym("currency", currency.String).
		Sym("quantity", nullableInt(d.quantity)).
		Sym("tax", "0").
		Sym("buyer_currency_display", display)
	if presentment {
		code := presentmentCurrency.String
		var value any
		if rails.Present(code) {
			lower := rails.Downcase(code)
			switch {
			case zeroDecimalCurrencies[lower]:
				value = presentmentTotal.Int64
			case products.CurrencyChoice(lower):
				// (amount_cents.to_f / 100).round(2) is the nearest Float to amount / 100.
				value = float64(presentmentTotal.Int64) / 100
			default:
				return nil, fallback("buyer presentment currency")
			}
		}
		event.Sym("buyer_presentment_currency", strings.ToUpper(code)).Sym("buyer_presentment_value", value)
	}
	return rails.NewRHash().
		Sym("seller_id", nullableString(d.ownerExternalID)).
		Sym("analytics", rails.NewRHash().
			Sym("google_analytics_id", nullableString(ga)).
			Sym("facebook_pixel_id", nullableString(pixel)).
			Sym("tiktok_pixel_id", tiktok).
			Sym("free_sales", ownerFlags.Int64&userSkipFreeSaleAnalytics == 0)).
		Sym("purchase_event", event), nil
}
