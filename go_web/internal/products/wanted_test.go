package products

import (
	"database/sql"
	"net/http"
	"strings"
	"testing"

	"github.com/antiwork/gumroad/go_web/internal/session/testdb"
)

// show's wanted=true sends the visitor to checkout with every param but the code, the cart
// item's product, rent and price, the code that applies, and the referrer. A pay-what-you-want
// product without a price renders the page, custom HTML aside.
func TestWantedSendsTheVisitorToCheckout(t *testing.T) {
	// to_query sorts the escaped pairs.
	const checkout = "https://gumroad.com/checkout?"
	const base = checkout + "action=show&controller=links&format=html"
	for _, c := range []struct {
		name, target, location, reason string
		headers                        map[string]string
		setup                          func(t *testing.T, e *testEnv, conn *sql.DB)
	}{
		{name: "the product", target: "/l/guide?wanted=true",
			location: base + "&id=guide&price=500&product=gowebp1&rent=false&wanted=true"},
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
		{name: "options", target: "/l/guide?wanted=true", reason: "wanted cart item",
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				testdb.Insert(t, conn, "variant_categories", map[string]any{"id": int64(1_799_311), "link_id": productID, "title": "Size"})
				testdb.Insert(t, conn, "base_variants", map[string]any{"id": int64(1_799_312), "type": "Variant", "variant_category_id": int64(1_799_311),
					"name": "S", "created_at": testNow, "updated_at": testNow})
			}},
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
	} {
		t.Run(c.name, func(t *testing.T) {
			e := newTestEnv(t)
			if c.setup != nil {
				c.setup(t, e, testdb.Open(t))
			}
			if c.reason != "" {
				e.renderAt(t, c.target, c.headers, c.reason)
				return
			}
			w := e.get(host, c.target, c.headers)
			if e.railsHit != nil {
				t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
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
