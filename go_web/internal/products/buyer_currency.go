package products

import (
	"database/sql"

	"github.com/antiwork/gumroad/go_web/internal/obfuscate"
	"github.com/antiwork/gumroad/go_web/internal/pages"
	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// CurrencyChoice is CURRENCY_CHOICES.key?(code).
func CurrencyChoice(code string) bool {
	_, ok := currencies[code]
	return ok
}

// BuyerCurrency is buyer_currency_display_props for pages other than the product page, which
// pass no preferred currency.
type BuyerCurrency struct{ h *handler }

// NewBuyerCurrency reads page's Redis, GeoIP and Flag, and nothing else of it.
func NewBuyerCurrency(conn *sql.DB, ids *obfuscate.IDs, page *PageConfig) *BuyerCurrency {
	return &BuyerCurrency{h: &handler{c: &Config{DB: conn, IDs: ids, Page: page}}}
}

// Display is buyer_currency_display_props(product:, price_cents: price, ip:) for productID,
// whose seller is the product's user. Shapes the product page leaves to Rails come back as the
// same fallbacks.
func (b *BuyerCurrency) Display(v *pages.Visit, productID, price int64, ip string) (*rails.RHash, error) {
	h := b.h
	prod := &product{}
	if err := h.c.DB.QueryRowContext(v.Ctx, "SELECT "+productColumns+" FROM links WHERE links.id = ? LIMIT 1", productID).
		Scan(prod.dest()...); err != nil {
		return nil, err
	}
	seller, err := userByID(v.Ctx, h.c.DB, prod.userID)
	if err != nil {
		return nil, err
	}
	if seller == nil {
		return nil, fallback("no product user")
	}
	sellerJSON, ok := parseJSONData(seller.jsonData)
	if !ok {
		return nil, fallback("seller json_data")
	}
	p := &page{Visit: v, seller: seller}
	on, err := h.creatorOptedIn(p, sellerJSON)
	if err != nil {
		return nil, err
	}
	var display *currencyDisplay
	if !on {
		return buyerCurrencyDisplay(h.c.IDs.Encrypt(prod.id), prod.productCurrency(), display), nil
	}
	if buyer := buyerCurrencyForCountry(countryCode(h.lookup(ip))); buyer != nil {
		var hasPlan bool
		if err := h.c.DB.QueryRowContext(v.Ctx, "SELECT EXISTS(SELECT 1 FROM product_installment_plans"+
			" WHERE product_installment_plans.link_id = ? AND product_installment_plans.deleted_at IS NULL)", prod.id).Scan(&hasPlan); err != nil {
			return nil, err
		}
		if display, err = h.currencyDisplayFor(p, prod, hasPlan, *buyer, &price); err != nil {
			return nil, err
		}
	}
	return buyerCurrencyDisplay(h.c.IDs.Encrypt(prod.id), prod.productCurrency(), display), nil
}
