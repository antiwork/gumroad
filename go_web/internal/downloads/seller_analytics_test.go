package downloads

import (
	"net/http"
	"testing"

	"github.com/antiwork/gumroad/go_web/internal/pages"
	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/session/testdb"
)

// fakeBuyerCurrency records what it was asked and shows the default display.
type fakeBuyerCurrency struct {
	productID, price int64
	ip               string
}

func (f *fakeBuyerCurrency) Display(_ *pages.Visit, productID, price int64, ip string) (*rails.RHash, error) {
	f.productID, f.price, f.ip = productID, price, ip
	return rails.NewRHash().Sym("display_mode", "default"), nil
}

func TestTheSellersAnalyticsDescribeThePurchase(t *testing.T) {
	e := newPageEnv(t)
	currency := &fakeBuyerCurrency{}
	e.pages.BuyerCurrency = currency
	e.db.Exec(`UPDATE users SET google_analytics_id = 'G-1', json_data = '{"tiktok_pixel_id":"TT1"}', flags = flags | ? WHERE id = ?`,
		userSkipFreeSaleAnalytics, sellerID)
	t.Cleanup(func() {
		e.db.Exec("UPDATE users SET google_analytics_id = NULL, json_data = NULL, flags = flags & ~? WHERE id = ?", userSkipFreeSaleAnalytics, sellerID)
	})
	analytics := func(purchase map[string]any, presentment map[string]any) string {
		t.Helper()
		row := map[string]any{"price_cents": 500, "displayed_price_cents": 500, "displayed_price_currency_type": "usd", "quantity": 2}
		for k, v := range purchase {
			row[k] = v
		}
		token := e.purchase(productID, row, nil)
		if presentment != nil {
			presentment["id"], presentment["purchase_id"] = nextPurchase, nextPurchase
			for k, v := range map[string]any{"processor": "stripe", "presentment_price_cents": 1, "presentment_gumroad_amount_cents": 1,
				"created_at": testNow, "updated_at": testNow} {
				presentment[k] = v
			}
			testdb.Insert(t, e.db, "purchase_presentments", presentment)
		}
		w := e.page(token, nil)
		if w.Code != http.StatusOK || e.railsHit != nil {
			t.Fatalf("status %d, rails %v", w.Code, e.railsHit != nil)
		}
		return rails.EncodeJSON(pageProps(t, w.Body.String()).Value("seller_analytics"))
	}

	got := analytics(nil, nil)
	want := `{"seller_id":"1780001","analytics":{"google_analytics_id":"G-1","facebook_pixel_id":null,"tiktok_pixel_id":"TT1","free_sales":false},` +
		`"purchase_event":{"permalink":"gowebdl101","purchase_external_id":"` + e.ids.Encrypt(nextPurchase) + `","product_name":"Download",` +
		`"value":500,"currency":"usd","quantity":2,"tax":"0","buyer_currency_display":{"display_mode":"default"}}}`
	if got != want {
		t.Errorf("seller analytics\n got %s\nwant %s", got, want)
	}
	// buyer_currency_display_props reads the purchase's own IP and displayed price.
	if currency.productID != productID || currency.price != 500 || currency.ip != buyerIP {
		t.Errorf("buyer currency asked for %+v", currency)
	}

	// A buyer charged in their own currency, in Stripe's units for it.
	for code, want := range map[string]string{"sek": `"buyer_presentment_currency":"SEK","buyer_presentment_value":123.45}}`,
		"jpy": `"buyer_presentment_currency":"JPY","buyer_presentment_value":12345}}`} {
		got := analytics(nil, map[string]any{"presentment_currency": code, "presentment_total_cents": 12345})
		if len(got) < len(want) || got[len(got)-len(want):] != want {
			t.Errorf("%s presentment: %s", code, got)
		}
	}
}

func TestSellerAnalyticsTheyCantPortGoToRails(t *testing.T) {
	e := newPageEnv(t)
	e.db.Exec("UPDATE users SET facebook_pixel_id = 'FB1' WHERE id = ?", sellerID)
	t.Cleanup(func() { e.db.Exec("UPDATE users SET facebook_pixel_id = NULL WHERE id = ?", sellerID) })
	// Without the product page's currency port there's no buyer_currency_display.
	token := e.purchase(productID, map[string]any{"price_cents": 500, "displayed_price_cents": 500}, nil)
	if e.page(token, nil); e.railsHit == nil {
		t.Error("rendered without the buyer currency port")
	}
	e.pages.BuyerCurrency = &fakeBuyerCurrency{}
	for name, purchase := range map[string]map[string]any{
		"seller tax":         {"tax_cents": 30},
		"no displayed price": {"displayed_price_cents": nil},
	} {
		row := map[string]any{"price_cents": 500, "displayed_price_cents": 500}
		for k, v := range purchase {
			row[k] = v
		}
		if e.page(e.purchase(productID, row, nil), nil); e.railsHit == nil {
			t.Errorf("%s: rendered", name)
		}
	}
}

func TestABlankTikTokIDIsNoAnalytics(t *testing.T) {
	e := newPageEnv(t)
	e.pages.BuyerCurrency = &fakeBuyerCurrency{}
	e.db.Exec(`UPDATE users SET json_data = '{"tiktok_pixel_id":" "}' WHERE id = ?`, sellerID)
	t.Cleanup(func() { e.db.Exec("UPDATE users SET json_data = NULL WHERE id = ?", sellerID) })
	w := e.page(e.purchase(productID, map[string]any{"price_cents": 500}, nil), nil)
	if w.Code != http.StatusOK || e.railsHit != nil {
		t.Fatalf("status %d, rails %v", w.Code, e.railsHit != nil)
	}
	if got := pageProps(t, w.Body.String()).Value("seller_analytics"); got != nil {
		t.Errorf("seller analytics %s", rails.EncodeJSON(got))
	}
}
