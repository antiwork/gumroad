package products

import (
	"database/sql"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"testing"

	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/session/testdb"
)

// price_cents_from_units reads a plain decimal in the currency's units.
func TestPriceCentsFromUnits(t *testing.T) {
	for _, c := range []struct {
		in    string
		scale int64
		want  int64
		ok    bool
	}{
		{"5", 100, 500, true}, {"5.", 100, 500, true}, {".5", 100, 50, true}, {"+1.005", 100, 101, true}, {"1.004", 100, 100, true},
		{"-0", 100, 0, true}, {"-1", 100, 0, false}, {"1e3", 100, 0, false}, {" 5", 100, 0, false}, {"5,00", 100, 0, false},
		{"1500.6", 1, 1501, true}, {"21474836.47", 100, 2147483647, true}, {"21474836.48", 100, 0, false}, {"", 100, 0, false},
	} {
		got, ok := priceCentsFromUnits(c.in, c.scale)
		if got != c.want || ok != c.ok {
			t.Errorf("%q: %d %v, want %d %v", c.in, got, ok, c.want, c.ok)
		}
	}
}

// show's wanted=true sends the visitor to checkout with every param but the code, the cart
// item's product, rent and price, the code that applies, and the referrer. A pay-what-you-want
// product without a price renders the page, custom HTML aside.
func TestWantedSendsTheVisitorToCheckout(t *testing.T) {
	// to_query sorts the escaped pairs.
	const checkout = "https://gumroad.com/checkout?"
	const base = checkout + "action=show&controller=links&format=html"
	const category, small, medium = int64(1_799_321), int64(1_799_322), int64(1_799_323)
	variant := func(t *testing.T, conn *sql.DB, id int64, position, maxPurchases, diff any, pwyw bool) {
		testdb.Insert(t, conn, "base_variants", map[string]any{"id": id, "type": "Variant", "variant_category_id": category, "name": "Size",
			"position_in_category": position, "max_purchase_count": maxPurchases, "sales_count_for_inventory_cache": 1,
			"price_difference_cents": diff, "customizable_price": pwyw, "created_at": testNow, "updated_at": testNow})
	}
	sizes := func(t *testing.T, conn *sql.DB, smallPWYW bool) {
		testdb.Insert(t, conn, "variant_categories", map[string]any{"id": category, "link_id": productID, "title": "Size"})
		variant(t, conn, small, 0, nil, nil, smallPWYW)
		variant(t, conn, medium, 1, nil, 200, false)
	}
	// The fixture's 500-cent price is the monthly one; duration is subscription_duration's enum value.
	membership := func(t *testing.T, conn *sql.DB, flags int64, duration int) {
		mustExec(t, conn, "UPDATE links SET flags = flags | ?, subscription_duration = ?, native_type = 'membership' WHERE id = ?",
			productIsRecurringBilling|flags, duration, productID)
		mustExec(t, conn, "UPDATE prices SET recurrence = 'monthly' WHERE id = ?", priceID)
		testdb.Insert(t, conn, "prices", map[string]any{"id": int64(1_799_331), "link_id": productID, "price_cents": 4000, "currency": "usd",
			"recurrence": "yearly", "created_at": testNow, "updated_at": testNow})
	}
	const tierCategory, basic, pro = int64(1_799_341), int64(1_799_342), int64(1_799_343)
	tier := func(t *testing.T, conn *sql.DB, id int64, position int, maxPurchases any, pwyw bool, prices ...[2]any) {
		testdb.Insert(t, conn, "base_variants", map[string]any{"id": id, "type": "Variant", "variant_category_id": tierCategory, "name": "Tier",
			"position_in_category": position, "max_purchase_count": maxPurchases, "sales_count_for_inventory_cache": 2,
			"customizable_price": pwyw, "created_at": testNow, "updated_at": testNow})
		for i, p := range prices {
			testdb.Insert(t, conn, "prices", map[string]any{"id": id + int64(i+1)*1000, "variant_id": id, "price_cents": p[0], "currency": "usd",
				"recurrence": p[1], "created_at": testNow, "updated_at": testNow})
		}
	}
	// Basic sells monthly and yearly; Pro monthly and quarterly.
	tiers := func(t *testing.T, conn *sql.DB, duration int, basicMax any, basicPWYW bool) {
		membership(t, conn, productIsTieredMembership, duration)
		testdb.Insert(t, conn, "variant_categories", map[string]any{"id": tierCategory, "link_id": productID, "title": "Tier"})
		tier(t, conn, basic, 0, basicMax, basicPWYW, [2]any{300, "monthly"}, [2]any{3000, "yearly"})
		tier(t, conn, pro, 1, nil, false, [2]any{900, "monthly"}, [2]any{1000, "quarterly"})
	}
	// rental adds a 300-cent rental price to the fixture.
	rental := func(t *testing.T, conn *sql.DB, purchaseType int) {
		mustExec(t, conn, "UPDATE links SET purchase_type = ? WHERE id = ?", purchaseType, productID)
		testdb.Insert(t, conn, "prices", map[string]any{"id": int64(1_799_351), "link_id": productID, "price_cents": 300, "currency": "usd",
			"flags": priceIsRental, "created_at": testNow, "updated_at": testNow})
	}
	for _, c := range []struct {
		name, target, location, reason string
		// targetFor and locationFor are the target and location when they name an option's
		// external id.
		targetFor, locationFor func(e *testEnv) string
		headers                map[string]string
		setup                  func(t *testing.T, e *testEnv, conn *sql.DB)
	}{
		{name: "the product", target: "/l/guide?wanted=true",
			location: base + "&id=guide&price=500&product=gowebp1&rent=false&wanted=true"},
		// The redirect never reads the profile's reputation rollup, the one cache read on its way.
		{name: "reputation on, with the cache down", target: "/l/guide?wanted=true",
			location: base + "&id=guide&price=500&product=gowebp1&rent=false&wanted=true",
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				e.redis.HSet("seller_reputation_summary", "boolean", "true")
				e.redis.Set("seller_reputation_summary/v2/snapshot/1790001",
					`{"aggregate":[3,30,120],"signature":0,"computed_at":`+strconv.FormatInt(testNow.Unix(), 10)+`}`)
				e.cache.readErr = errors.New("down")
			}},
		{name: "other params and the referrer", target: "/l/guide?wanted=true&utm_source=a+b&product=x&affiliate_id=",
			headers: map[string]string{"Referer": "https://example.com/r?x=1"},
			// The request's String keys and checkout_url's own Symbol ones both reach the query.
			location: checkout + "action=show&affiliate_id=&affiliate_id=&controller=links&format=html&id=guide&price=500&product=gowebp1" +
				"&product=x&referrer=https%3A%2F%2Fexample.com%2Fr%3Fx%3D1&rent=false&utm_source=a+b&wanted=true"},
		{name: "a referrer param over the header", target: "/l/guide?wanted=true&referrer=email&a=7",
			headers: map[string]string{"Referer": "https://example.com/r"},
			location: checkout + "a=7&action=show&affiliate_id=7&controller=links&format=html&id=guide&price=500&product=gowebp1" +
				"&referrer=email&referrer=email&rent=false&wanted=true"},
		{name: "the code in the path, which applies", target: "/l/guide/save10?wanted=true",
			location: checkout + "action=show&code=save10&controller=links&format=html&id=guide&price=500&product=gowebp1&rent=false&wanted=true",
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				insertOfferCode(t, conn, 1_799_301, map[string]any{"code": "SAVE10", "amount_percentage": 10, "universal": true})
			}},
		{name: "the sale", target: "/l/guide?wanted=true",
			location: checkout + "action=show&code=SALE20&controller=links&format=html&id=guide&price=500&product=gowebp1&rent=false&wanted=true",
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				insertOfferCode(t, conn, 1_799_302, map[string]any{"code": "SALE20", "amount_percentage": 20, "universal": true, "auto_apply": true})
			}},
		// The redirect weighs the URL's code against the sale at the cart item's price.
		{name: "a code beside a bigger sale", target: "/l/guide/save10?wanted=true",
			location: checkout + "action=show&code=SALE20&controller=links&format=html&id=guide&price=500&product=gowebp1&rent=false&wanted=true",
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				insertOfferCode(t, conn, 1_799_301, map[string]any{"code": "SAVE10", "amount_percentage": 10, "universal": true})
				insertOfferCode(t, conn, 1_799_302, map[string]any{"code": "SALE20", "amount_percentage": 20, "universal": true, "auto_apply": true})
			}},
		{name: "a code bigger than the sale", target: "/l/guide/save10?wanted=true",
			location: checkout + "action=show&code=save10&controller=links&format=html&id=guide&price=500&product=gowebp1&rent=false&wanted=true",
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				insertOfferCode(t, conn, 1_799_301, map[string]any{"code": "SAVE10", "amount_percentage": 30, "universal": true})
				insertOfferCode(t, conn, 1_799_302, map[string]any{"code": "SALE20", "amount_percentage": 20, "universal": true, "auto_apply": true})
			}},
		// $1.50 off beats 20% at the 500-cent display price, but not at the 2,000 cents paid.
		{name: "a code beside a sale bigger at the price paid", target: "/l/guide/save10?wanted=true&price=20",
			location: checkout + "action=show&code=SALE20&controller=links&format=html&id=guide&price=2000&price=2000&product=gowebp1&rent=false&wanted=true",
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				mustExec(t, conn, "UPDATE links SET customizable_price = TRUE WHERE id = ?", productID)
				insertOfferCode(t, conn, 1_799_301, map[string]any{"code": "SAVE10", "amount_cents": 150, "currency_type": "usd", "universal": true})
				insertOfferCode(t, conn, 1_799_302, map[string]any{"code": "SALE20", "amount_percentage": 20, "universal": true, "auto_apply": true})
			}},
		{name: "a code that doesn't apply", target: "/l/guide/nope?wanted=true",
			location: base + "&id=guide&price=500&product=gowebp1&rent=false&wanted=true"},
		{name: "a wanted that isn't true", target: "/l/guide?wanted=1"},
		{name: "a pay-what-you-want product", target: "/l/guide?wanted=true",
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				mustExec(t, conn, "UPDATE links SET customizable_price = TRUE WHERE id = ?", productID)
			}},
		{name: "a pay-what-you-want product with custom HTML", target: "/l/guide?wanted=true",
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				mustExec(t, conn, "UPDATE links SET customizable_price = TRUE WHERE id = ?", productID)
				customHTML(t, e, conn)
			}},
		// cart_item takes the first option with any left, and its price difference.
		{name: "options", target: "/l/guide?wanted=true", location: base + "&id=guide&price=500&product=gowebp1&rent=false&wanted=true",
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) { sizes(t, conn, false) }},
		{name: "options, the first sold out", target: "/l/guide?wanted=true", location: base + "&id=guide&price=700&product=gowebp1&rent=false&wanted=true",
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				sizes(t, conn, false)
				mustExec(t, conn, "UPDATE base_variants SET max_purchase_count = 1 WHERE id = ?", small)
			}},
		{name: "a pay-what-you-want option", target: "/l/guide?wanted=true",
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) { sizes(t, conn, true) }},
		// Variant.find_by_external_id finds no SKU, so a SKU is never pay what you want.
		{name: "a SKU", target: "/l/guide?wanted=true", location: base + "&id=guide&price=650&product=gowebp1&rent=false&wanted=true",
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				mustExec(t, conn, "UPDATE links SET flags = flags | ?, native_type = 'physical', require_shipping = 1 WHERE id = ?",
					productIsPhysical|productSkusEnabled, productID)
				testdb.Insert(t, conn, "base_variants", map[string]any{"id": int64(1_799_324), "type": "Sku", "link_id": productID, "name": "Blue",
					"price_difference_cents": 150, "customizable_price": true, "created_at": testNow, "updated_at": testNow})
			}},
		// The recurrence is the subscription duration's when a price has it, else the shortest.
		{name: "a membership", target: "/l/guide?wanted=true",
			location: base + "&id=guide&price=4000&product=gowebp1&recurrence=yearly&rent=false&wanted=true",
			setup:    func(t *testing.T, e *testEnv, conn *sql.DB) { membership(t, conn, 0, 1) }},
		{name: "a membership with no price at its duration", target: "/l/guide?wanted=true",
			location: base + "&id=guide&price=500&product=gowebp1&recurrence=monthly&rent=false&wanted=true",
			setup:    func(t *testing.T, e *testEnv, conn *sql.DB) { membership(t, conn, 0, 2) }},
		// A tier's own prices.
		{name: "a tiered membership", target: "/l/guide?wanted=true",
			location: base + "&id=guide&price=300&product=gowebp1&recurrence=monthly&rent=false&wanted=true",
			setup:    func(t *testing.T, e *testEnv, conn *sql.DB) { tiers(t, conn, 0, nil, false) }},
		{name: "a tiered membership at its yearly duration", target: "/l/guide?wanted=true",
			location: base + "&id=guide&price=3000&product=gowebp1&recurrence=yearly&rent=false&wanted=true",
			setup:    func(t *testing.T, e *testEnv, conn *sql.DB) { tiers(t, conn, 1, nil, false) }},
		// Pro has no yearly price, so its shortest.
		{name: "a tiered membership past a sold-out tier", target: "/l/guide?wanted=true",
			location: base + "&id=guide&price=900&product=gowebp1&recurrence=monthly&rent=false&wanted=true",
			setup:    func(t *testing.T, e *testEnv, conn *sql.DB) { tiers(t, conn, 1, 2, false) }},
		// default_price_recurrence reads the product's prices, which have no quarterly one.
		{name: "a tier's price at a duration the product has none at", target: "/l/guide?wanted=true",
			location: base + "&id=guide&price=900&product=gowebp1&recurrence=monthly&rent=false&wanted=true",
			setup:    func(t *testing.T, e *testEnv, conn *sql.DB) { tiers(t, conn, 2, 2, false) }},
		// With no tier left, cart_item reads the product's own prices.
		{name: "a tiered membership with every tier sold out", target: "/l/guide?wanted=true",
			location: base + "&id=guide&price=500&product=gowebp1&recurrence=monthly&rent=false&wanted=true",
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				tiers(t, conn, 0, 2, false)
				mustExec(t, conn, "UPDATE base_variants SET max_purchase_count = 2 WHERE id = ?", pro)
			}},
		{name: "a tier closed to new buyers", target: "/l/guide?wanted=true",
			location: base + "&id=guide&price=900&product=gowebp1&recurrence=monthly&rent=false&wanted=true",
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				e.redis.HSet("close_membership_tier_to_new_buyers", "boolean", "true")
				tiers(t, conn, 0, nil, false)
				mustExec(t, conn, "UPDATE base_variants SET flags = ? WHERE id = ?", baseVariantClosedToNewPurchases, basic)
			}},
		{name: "a membership with no recurring price", target: "/l/guide?wanted=true",
			location: base + "&id=guide&price=0&product=gowebp1&rent=false&wanted=true",
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				mustExec(t, conn, "UPDATE links SET flags = flags | ?, subscription_duration = 0, native_type = 'membership' WHERE id = ?",
					productIsRecurringBilling, productID)
			}},
		{name: "an option's difference below zero", target: "/l/guide?wanted=true",
			location: base + "&id=guide&price=0&product=gowebp1&rent=false&wanted=true",
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				sizes(t, conn, false)
				mustExec(t, conn, "UPDATE base_variants SET max_purchase_count = 1 WHERE id = ?", small)
				mustExec(t, conn, "UPDATE base_variants SET price_difference_cents = -700 WHERE id = ?", medium)
			}},
		{name: "the minimum after an option's difference", target: "/l/guide?wanted=true",
			location: base + "&id=guide&price=99&product=gowebp1&rent=false&wanted=true",
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				mustExec(t, conn, "UPDATE users SET flags = flags | ? WHERE id = ?", userPPPEnabled, sellerID)
				sizes(t, conn, false)
				mustExec(t, conn, "UPDATE base_variants SET max_purchase_count = 1 WHERE id = ?", small)
				mustExec(t, conn, "UPDATE base_variants SET price_difference_cents = -450 WHERE id = ?", medium)
			}},
		{name: "a pay-what-you-want tier", target: "/l/guide?wanted=true",
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) { tiers(t, conn, 0, nil, true) }},
		// cart_item raises a price under the currency's minimum to it.
		{name: "a price under the minimum", target: "/l/guide?wanted=true", location: base + "&id=guide&price=99&product=gowebp1&rent=false&wanted=true",
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				mustExec(t, conn, "UPDATE users SET flags = flags | ? WHERE id = ?", userPPPEnabled, sellerID)
				mustExec(t, conn, "UPDATE prices SET price_cents = 50 WHERE link_id = ?", productID)
			}},
		{name: "an Array param", target: "/l/guide?wanted=true&tag[]=x", reason: "wanted params"},
		// Only url_for's Symbol keys are its own.
		{name: "a String key url_for reserves", target: "/l/guide?wanted=true&anchor=x",
			location: checkout + "action=show&anchor=x&controller=links&format=html&id=guide&price=500&product=gowebp1&rent=false&wanted=true"},
		{name: "a coffee product", target: "/l/guide?wanted=1", location: "https://gowebproductseller.gumroad.com/coffee?wanted=1",
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				mustExec(t, conn, "UPDATE links SET native_type = 'coffee' WHERE id = ?", productID)
			}},
		// params.permit(:wanted, :native) goes through to_query, which sorts its keys.
		{name: "a coffee product with native", target: "/l/guide?wanted=1&native=true&x=2",
			location: "https://gowebproductseller.gumroad.com/coffee?native=true&wanted=1",
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				mustExec(t, conn, "UPDATE links SET native_type = 'coffee' WHERE id = ?", productID)
			}},
		// show fills in params[:option] from the variant's name, and the redirect carries it.
		{name: "a variant by name", target: "/l/guide?wanted=true&variant=Medium",
			locationFor: func(e *testEnv) string {
				return base + "&id=guide&option=" + rails.CGIEscape(e.ids.Encrypt(medium)) + "&price=700&product=gowebp1&rent=false&variant=Medium&wanted=true"
			},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				sizes(t, conn, false)
				mustExec(t, conn, "UPDATE base_variants SET name = 'Medium' WHERE id = ?", medium)
			}},
		{name: "a variant no option has", target: "/l/guide?wanted=true&variant=Large",
			location: base + "&id=guide&price=500&product=gowebp1&rent=false&variant=Large&wanted=true",
			setup:    func(t *testing.T, e *testEnv, conn *sql.DB) { sizes(t, conn, false) }},
		// A blank option isn't nil, so the variant doesn't replace it, and it names no option.
		{name: "a blank option", target: "/l/guide?wanted=true&option=&variant=Size",
			location: base + "&id=guide&option=&price=700&product=gowebp1&rent=false&variant=Size&wanted=true",
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				sizes(t, conn, false)
				mustExec(t, conn, "UPDATE base_variants SET max_purchase_count = 1 WHERE id = ?", small)
			}},
		// A requested option need not have any left.
		{name: "a sold-out option by id",
			targetFor: func(e *testEnv) string { return "/l/guide?wanted=true&option=" + rails.CGIEscape(e.ids.Encrypt(small)) },
			locationFor: func(e *testEnv) string {
				return base + "&id=guide&option=" + rails.CGIEscape(e.ids.Encrypt(small)) + "&price=500&product=gowebp1&rent=false&wanted=true"
			},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				sizes(t, conn, false)
				mustExec(t, conn, "UPDATE base_variants SET max_purchase_count = 1 WHERE id = ?", small)
			}},
		{name: "a tier by id",
			targetFor: func(e *testEnv) string { return "/l/guide?wanted=true&option=" + rails.CGIEscape(e.ids.Encrypt(pro)) },
			locationFor: func(e *testEnv) string {
				return base + "&id=guide&option=" + rails.CGIEscape(e.ids.Encrypt(pro)) + "&price=900&product=gowebp1&recurrence=monthly&rent=false&wanted=true"
			},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) { tiers(t, conn, 0, nil, false) }},
		// The first recurrence flagged true fills in params[:recurrence], which wins over the duration.
		{name: "a recurrence flag", target: "/l/guide?wanted=true&quarterly=false&monthly=true&yearly=true",
			location: base + "&id=guide&monthly=true&price=500&product=gowebp1&quarterly=false&recurrence=monthly&recurrence=monthly&rent=false&wanted=true&yearly=true",
			setup:    func(t *testing.T, e *testEnv, conn *sql.DB) { membership(t, conn, 0, 1) }},
		{name: "a recurrence over a flag", target: "/l/guide?wanted=true&recurrence=monthly&yearly=true",
			location: base + "&id=guide&price=500&product=gowebp1&recurrence=monthly&recurrence=monthly&rent=false&wanted=true&yearly=true",
			setup:    func(t *testing.T, e *testEnv, conn *sql.DB) { membership(t, conn, 0, 1) }},
		{name: "a recurrence the product has no price at", target: "/l/guide?wanted=true&recurrence=quarterly",
			location: base + "&id=guide&price=4000&product=gowebp1&recurrence=quarterly&recurrence=yearly&rent=false&wanted=true",
			setup:    func(t *testing.T, e *testEnv, conn *sql.DB) { membership(t, conn, 0, 1) }},
		// price_cents_from_units: a pay-what-you-want price that covers the product's goes to
		// checkout, in cents both times.
		{name: "a pay-what-you-want price", target: "/l/guide?wanted=true&price=7.505",
			location: base + "&id=guide&price=751&price=751&product=gowebp1&rent=false&wanted=true",
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				mustExec(t, conn, "UPDATE links SET customizable_price = TRUE WHERE id = ?", productID)
			}},
		{name: "a pay-what-you-want price under the product's", target: "/l/guide?wanted=true&price=4",
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				mustExec(t, conn, "UPDATE links SET customizable_price = TRUE WHERE id = ?", productID)
			}},
		{name: "a pay-what-you-want option's price", target: "/l/guide?wanted=true&price=6",
			location: base + "&id=guide&price=600&price=600&product=gowebp1&rent=false&wanted=true",
			setup:    func(t *testing.T, e *testEnv, conn *sql.DB) { sizes(t, conn, true) }},
		// An unreadable price is nil, which url_for drops; only pay what you want reads it.
		{name: "an unreadable price", target: "/l/guide?wanted=true&price=5%2C00",
			location: base + "&id=guide&price=500&product=gowebp1&rent=false&wanted=true"},
		{name: "a price that isn't pay what you want", target: "/l/guide?wanted=true&price=9",
			location: base + "&id=guide&price=500&price=900&product=gowebp1&rent=false&wanted=true"},
		{name: "a blank price", target: "/l/guide?wanted=true&price=",
			location: base + "&id=guide&price=&price=500&product=gowebp1&rent=false&wanted=true"},
		// !!params[:rent], so any value but a bare key rents what rents.
		{name: "a rental", target: "/l/guide?wanted=true&rent=false",
			location: base + "&id=guide&price=300&product=gowebp1&rent=false&rent=true&wanted=true",
			setup:    func(t *testing.T, e *testEnv, conn *sql.DB) { rental(t, conn, purchaseTypeBuyAndRent) }},
		{name: "a rental of what only sells", target: "/l/guide?wanted=true&rent=1",
			location: base + "&id=guide&price=500&product=gowebp1&rent=1&rent=false&wanted=true",
			setup:    func(t *testing.T, e *testEnv, conn *sql.DB) { rental(t, conn, purchaseTypeBuyOnly) }},
		{name: "an Array option", target: "/l/guide?wanted=true&option[]=x", reason: "wanted params"},
	} {
		t.Run(c.name, func(t *testing.T) {
			e := newTestEnv(t)
			if c.setup != nil {
				c.setup(t, e, testdb.Open(t))
			}
			if c.targetFor != nil {
				c.target = c.targetFor(e)
			}
			if c.reason != "" {
				e.renderAt(t, c.target, c.headers, c.reason)
				return
			}
			w := e.get(host, c.target, c.headers)
			if e.railsHit != nil {
				t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
			}
			if c.locationFor != nil {
				c.location = c.locationFor(e)
			}
			if c.location == "" {
				if w.Code != http.StatusOK {
					t.Fatalf("%d, location %q", w.Code, w.Header().Get("Location"))
				}
				componentProps(t, w.Body.String(), productComponent)
				return
			}
			if w.Code != http.StatusFound || w.Header().Get("Location") != c.location {
				t.Errorf("%d %q\nwant %q", w.Code, w.Header().Get("Location"), c.location)
			}
			// set_x_robots_tag_header marks a code in the URL.
			if robots := w.Header().Get("X-Robots-Tag"); (robots == "noindex") != (strings.Contains(c.target, "/save10") || strings.Contains(c.target, "/nope")) {
				t.Errorf("X-Robots-Tag %q", robots)
			}
		})
	}
}
