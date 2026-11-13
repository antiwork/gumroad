package products

import (
	"context"
	"testing"

	"github.com/antiwork/gumroad/go_web/internal/geoip"
	"github.com/antiwork/gumroad/go_web/internal/geoip/geoiptest"
	"github.com/antiwork/gumroad/go_web/internal/pages"
	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/session/testdb"
)

func TestBuyerCurrencyDisplaysThePriceForTheBuyersIP(t *testing.T) {
	const gb, unplaced = "81.2.69.142", "8.8.8.8"
	display := func(e *testEnv, shown, local, rate, mode string) string {
		return `{"product_id":"` + e.ids.Encrypt(productID) + `","buyer_currency_shown":"` + shown + `","product_currency":"usd",` +
			`"buyer_local_price_cents":` + local + `,"rate":` + rate + `,"display_mode":"` + mode + `"}`
	}
	for _, c := range []struct {
		name, ip string
		setup    func(e *testEnv)
		want     func(e *testEnv) string
	}{
		{name: "a seller who hasn't opted in", ip: gb, want: func(e *testEnv) string { return display(e, "usd", "null", "null", "default") }},
		{name: "a buyer in the UK", ip: gb, setup: func(e *testEnv) {
			e.redis.HSet("buyer_local_currency", "boolean", "true")
			e.redis.Set("currencies:GBP", "0.79")
		}, want: func(e *testEnv) string { return display(e, "gbp", "395", "0.79", "buyer_local") }},
		{name: "a buyer GeoIP can't place", ip: unplaced, setup: func(e *testEnv) {
			e.redis.HSet("buyer_local_currency", "boolean", "true")
			e.redis.Set("currencies:GBP", "0.79")
		}, want: func(e *testEnv) string { return display(e, "usd", "null", "null", "default") }},
		{name: "a seller who turned it off", ip: gb, setup: func(e *testEnv) {
			e.redis.HSet("buyer_local_currency", "boolean", "true")
			e.redis.Set("currencies:GBP", "0.79")
			testdb.Open(e.t).Exec(`UPDATE users SET json_data = '{"disable_buyer_local_currency":true}' WHERE id = ?`, sellerID)
		}, want: func(e *testEnv) string { return display(e, "usd", "null", "null", "default") }},
	} {
		t.Run(c.name, func(t *testing.T) {
			e := newTestEnv(t)
			reader, err := geoip.Open(geoiptest.WriteDatabase(t))
			if err != nil {
				t.Fatal(err)
			}
			e.config.Page.GeoIP = reader
			conn := testdb.Open(t)
			t.Cleanup(func() { conn.Exec("UPDATE users SET json_data = NULL WHERE id = ?", sellerID) })
			if c.setup != nil {
				c.setup(e)
			}
			b := NewBuyerCurrency(conn, e.ids, e.config.Page)
			v := &pages.Visit{Ctx: context.Background(), Req: &rails.Request{Now: testNow}}
			got, err := b.Display(v, productID, 500, c.ip)
			if err != nil {
				t.Fatal(err)
			}
			if s := rails.EncodeJSON(got); s != c.want(e) {
				t.Errorf("display\n got %s\nwant %s", s, c.want(e))
			}
		})
	}
}
