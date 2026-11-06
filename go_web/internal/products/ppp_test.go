package products

import (
	"testing"

	"github.com/antiwork/gumroad/go_web/internal/geoip"
	"github.com/antiwork/gumroad/go_web/internal/geoip/geoiptest"
	"github.com/antiwork/gumroad/go_web/internal/session/testdb"
)

func TestAPurchasingPowerParityPrice(t *testing.T) {
	gb := map[string]string{"X-Forwarded-For": "81.2.69.1"}
	for _, c := range []struct {
		name, factor string
		limit        any
		setup        func(e *testEnv)
		wants        []string
		reason       string
	}{
		{name: "half price in the buyer's country", factor: "0.5", wants: []string{
			`"ppp_details":{"country":"United Kingdom","factor":0.5,"minimum_price":99}`,
			`"buyer_currency_display":{"product_id":"%[1]s","buyer_currency_shown":"usd","product_currency":"usd","buyer_local_price_cents":null`}},
		// The seller's limit raises the factor: [0.5, 1 - 30 / 100.0].max.
		{name: "the seller's limit", factor: "0.5", limit: 30, wants: []string{`"ppp_details":{"country":"United Kingdom","factor":0.7,"minimum_price":99}`}},
		{name: "no discount at a factor of 1", factor: "1", wants: []string{`"ppp_details":null`}},
		// [-0.5, 0].max keeps the Integer 0.
		{name: "a negative factor", factor: "-0.5", reason: "ppp factor"},
		// The local price is the lowered one; the original converts at the display's Float rate.
		{name: "a local price", factor: "0.5", setup: func(e *testEnv) {
			e.redis.HSet("buyer_local_currency", "boolean", "true")
			e.redis.Set("currencies:GBP", "0.79")
		}, wants: []string{`"buyer_local_price_cents":198,"rate":0.79,"display_mode":"buyer_local"}`,
			`"buyer_local_price_cents":198,"buyer_local_original_price_cents":395,"rental_price_cents"`}},
		// String#to_f reads the leading number.
		{name: "a factor with trailing text", factor: "0.5x", wants: []string{`"ppp_details":{"country":"United Kingdom","factor":0.5,`}},
	} {
		t.Run(c.name, func(t *testing.T) {
			e := newTestEnv(t)
			reader, err := geoip.Open(geoiptest.WriteDatabase(t))
			if err != nil {
				t.Fatal(err)
			}
			e.config.Page.GeoIP = reader
			conn := testdb.Open(t)
			conn.Exec("UPDATE users SET flags = flags | ?, purchasing_power_parity_limit = ? WHERE id = ?", userPPPEnabled, c.limit, sellerID)
			e.redis.Set("ppp:GB", c.factor)
			if c.setup != nil {
				c.setup(e)
			}
			body := e.render(t, gb, c.reason)
			e.wantAll(t, body, c.wants, productID)
		})
	}
}
