package products

import (
	"database/sql"
	"fmt"
	"maps"
	"strings"
	"testing"

	"github.com/antiwork/gumroad/go_web/internal/session/testdb"
)

// insertBuild adds build number n of the product, its site unpacked unless columns say otherwise.
func insertBuild(t *testing.T, conn *sql.DB, n int64, columns map[string]any) {
	row := map[string]any{"id": 1_788_100 + n, "product_id": productID, "public_id": fmt.Sprint("gowebbuild", n), "number": n,
		"status": "uploaded", "source_url": fmt.Sprint("https://example.com/", n, ".zip"), "storage_key": fmt.Sprint("builds/", n),
		"byte_size": 1, "site_unpacked_at": testNow, "created_at": testNow, "updated_at": testNow}
	maps.Copy(row, columns)
	testdb.Insert(t, conn, "product_builds", row)
}

// demoReady turns on both flags and makes the seller older than PROVEN_ACCOUNT_AGE, so only the
// build and the product decide the card.
func demoReady(t *testing.T, e *testEnv, conn *sql.DB) {
	e.redis.HSet("product_build_demo", "boolean", "true")
	e.redis.HSet("product_build_player", "boolean", "true")
	mustExec(t, conn, "UPDATE users SET created_at = ? WHERE id = ?", testNow.AddDate(0, 0, -31), sellerID)
}

func freeProduct(t *testing.T, conn *sql.DB) {
	mustExec(t, conn, "UPDATE prices SET price_cents = 0 WHERE id = ?", priceID)
}

var (
	liveBuild     = map[string]any{"status": "live"}
	selectedBuild = map[string]any{"demo_selected_at": testNow}
)

func TestAPublicDemoTakesTheXCard(t *testing.T) {
	sellerAge := func(days int) func(t *testing.T, e *testEnv, conn *sql.DB) {
		return func(t *testing.T, e *testEnv, conn *sql.DB) {
			mustExec(t, conn, "UPDATE users SET created_at = ? WHERE id = ?", testNow.AddDate(0, 0, -days), sellerID)
		}
	}
	version := func(difference, price int) func(t *testing.T, e *testEnv, conn *sql.DB) {
		return func(t *testing.T, e *testEnv, conn *sql.DB) {
			freeProduct(t, conn)
			testdb.Insert(t, conn, "variant_categories", map[string]any{"id": int64(1_788_401), "link_id": productID, "title": "Edition"})
			testdb.Insert(t, conn, "base_variants", map[string]any{"id": int64(1_788_501), "type": "Variant", "variant_category_id": int64(1_788_401),
				"name": "Deluxe", "price_difference_cents": difference, "created_at": testNow, "updated_at": testNow})
			testdb.Insert(t, conn, "prices", map[string]any{"id": int64(1_788_601), "variant_id": int64(1_788_501), "price_cents": price,
				"currency": "usd", "created_at": testNow, "updated_at": testNow})
		}
	}
	free := func(t *testing.T, e *testEnv, conn *sql.DB) { freeProduct(t, conn) }
	for _, c := range []struct {
		name  string
		card  bool
		build map[string]any // build 1
		setup func(t *testing.T, e *testEnv, conn *sql.DB)
	}{
		{name: "a paid product's chosen build", card: true, build: selectedBuild},
		{name: "a free product's live build", card: true, build: liveBuild, setup: free},
		// What buyers of a paid product get never becomes public, chosen or not.
		{name: "a paid product's live build", build: liveBuild},
		{name: "a paid product's chosen live build", build: map[string]any{"status": "live", "demo_selected_at": testNow}},
		{name: "a free product's chosen live build", card: true, build: map[string]any{"status": "live", "demo_selected_at": testNow}, setup: free},
		// min_by takes the chosen build over an earlier live one, whose site isn't ready.
		{name: "a chosen build after a live one", card: true, build: map[string]any{"status": "live", "site_unpacked_at": nil},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) { insertBuild(t, conn, 2, selectedBuild) }},
		// Rails reads a zero date as nil, which demo_selected.exists? still finds.
		{name: "a live build beside a zero-dated choice", build: liveBuild, setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			freeProduct(t, conn)
			insertBuild(t, conn, 2, map[string]any{"demo_selected_at": "0000-00-00 00:00:00"})
		}},
		{name: "an unpacked site", build: map[string]any{"demo_selected_at": testNow, "site_unpacked_at": nil}},
		// MySQL's collation matches it to live, which live? doesn't.
		{name: "a build whose status only matches live in SQL", build: map[string]any{"status": "LIVE"}, setup: free},
		{name: "the demo flag off", build: selectedBuild, setup: func(t *testing.T, e *testEnv, conn *sql.DB) { e.redis.Del("product_build_demo") }},
		{name: "the player flag off", build: selectedBuild, setup: func(t *testing.T, e *testEnv, conn *sql.DB) { e.redis.Del("product_build_player") }},
		{name: "an unpublished product", build: selectedBuild, setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			mustExec(t, conn, "UPDATE links SET draft = 1 WHERE id = ?", productID)
		}},
		{name: "a preorder", build: selectedBuild, setup: func(t *testing.T, e *testEnv, conn *sql.DB) { preorder(t, conn, testNow.AddDate(0, 1, 0)) }},
		{name: "a suspended seller", build: selectedBuild, setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			mustExec(t, conn, "UPDATE users SET user_risk_state = 'suspended_for_fraud' WHERE id = ?", sellerID)
		}},
		{name: "a new seller", build: selectedBuild, setup: sellerAge(29)},
		// 30.days.ago itself is old enough.
		{name: "a seller exactly 30 days old", card: true, build: selectedBuild, setup: sellerAge(30)},
		{name: "a new seller with a paid sale", card: true, build: selectedBuild, setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			sellerAge(29)(t, e, conn)
			addPurchase(t, conn, 1_788_301, nil)
		}},
		{name: "a new seller whose sale was refunded", build: selectedBuild, setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			sellerAge(29)(t, e, conn)
			addPurchase(t, conn, 1_788_301, map[string]any{"stripe_refunded": true})
		}},
		{name: "a new seller on Gumroad staff", card: true, build: selectedBuild, setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			sellerAge(29)(t, e, conn)
			mustExec(t, conn, "UPDATE users SET email = 'Seller@Gumroad.COM', confirmed_at = ? WHERE id = ?", testNow, sellerID)
		}},
		{name: "a new seller with an unconfirmed Gumroad email", build: selectedBuild, setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			sellerAge(29)(t, e, conn)
			mustExec(t, conn, "UPDATE users SET email = 'seller@gumroad.com' WHERE id = ?", sellerID)
		}},
		{name: "a free product with a paid version", build: liveBuild, setup: version(100, 0)},
		{name: "a free product with a version price", build: liveBuild, setup: version(0, 100)},
		{name: "a free product with a free version", card: true, build: liveBuild, setup: version(0, 0)},
	} {
		t.Run(c.name, func(t *testing.T) {
			e := newTestEnv(t)
			conn := testdb.Open(t)
			addCover(t, true)
			demoReady(t, e, conn)
			insertBuild(t, conn, 1, c.build)
			if c.setup != nil {
				c.setup(t, e, conn)
			}
			body := e.render(t, nil, "")
			tag := func(property, content string) string {
				return `<meta property="` + property + `" content="` + content + `" inertia="meta-property-` +
					strings.NewReplacer(":", "-").Replace(property) + `">` + "\n"
			}
			const retina = "https://public-files.gumroad.com/covers/retina"
			card := tag("twitter:card", "summary_large_image") + tag("twitter:image", retina) + tag("twitter:image:alt", "")
			if c.card {
				card = tag("twitter:card", "player") + tag("twitter:image", retina) + tag("twitter:player", "https://gumroad.com/demo/%[1]s") +
					tag("twitter:player:width", "640") + tag("twitter:player:height", "480")
			}
			e.wantAll(t, body, []string{tag("twitter:title", "Guide <1>") + card + `<meta property="twitter:domain"`}, productID)
		})
	}
}

func TestTheCustomHTMLWrapperTakesTheDemoCard(t *testing.T) {
	const image = "https://images.unsplash.com/a?b=1&amp;c"
	for _, c := range []struct {
		name  string
		build map[string]any
		free  bool
	}{
		{name: "a paid product's chosen build", build: selectedBuild},
		{name: "a free product's live build", build: liveBuild, free: true},
	} {
		t.Run(c.name, func(t *testing.T) {
			e := newTestEnv(t)
			conn := testdb.Open(t)
			customHTML(t, e, conn)
			demoReady(t, e, conn)
			testdb.Insert(t, conn, "thumbnails", map[string]any{"id": int64(1_788_701), "product_id": productID,
				"unsplash_url": "https://images.unsplash.com/a?b=1&c", "created_at": testNow, "updated_at": testNow})
			if c.free {
				freeProduct(t, conn)
			}
			insertBuild(t, conn, 1, c.build)
			w := e.get(host, "/l/guide", nil)
			if w.Code != 200 || e.railsHit != nil {
				t.Fatalf("%d %q, Rails hit: %v", w.Code, w.Header().Get("X-Go-Web-Fallback"), e.railsHit != nil)
			}
			e.wantAll(t, w.Body.String(), []string{strings.Join([]string{
				`<meta property="og:image" content="` + image + `">`,
				`<meta property="twitter:card" content="player">`,
				`<meta property="twitter:image" content="` + image + `">`,
				`<meta property="twitter:player" content="https://gumroad.com/demo/%[1]s">`,
				`<meta property="twitter:player:width" content="640">`,
				`<meta property="twitter:player:height" content="480">`,
				`<script type="application/ld+json">`,
			}, "\n    ")}, productID)
		})
	}
}
