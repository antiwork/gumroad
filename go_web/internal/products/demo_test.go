package products

import (
	"database/sql"
	"maps"
	"strings"
	"testing"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/session/testdb"
)

// demo_player_card_meta: the product's public demo build plays in its X player card, in place of
// the cover's card.
func TestAProductBuildsDemoPlayerCard(t *testing.T) {
	const buildID = int64(1_799_401)
	retina := "https://public-files.gumroad.com/covers/retina"
	free := func(t *testing.T, e *testEnv, conn *sql.DB) {
		mustExec(t, conn, "UPDATE links SET price_cents = 0 WHERE id = ?", productID)
		mustExec(t, conn, "UPDATE prices SET price_cents = 0 WHERE id = ?", priceID)
	}
	recent := func(t *testing.T, e *testEnv, conn *sql.DB) {
		mustExec(t, conn, "UPDATE users SET created_at = ? WHERE id = ?", testNow.Add(-24*time.Hour), sellerID)
	}
	// second adds a build numbered after the case's own.
	second := func(columns map[string]any) func(t *testing.T, e *testEnv, conn *sql.DB) {
		return func(t *testing.T, e *testEnv, conn *sql.DB) {
			row := map[string]any{"id": buildID + 1, "product_id": productID, "public_id": "gowebbuild2", "number": 2,
				"source_url": "https://example.com/build2.zip", "storage_key": "builds/2", "byte_size": 1, "site_unpacked_at": testNow,
				"created_at": testNow, "updated_at": testNow}
			maps.Copy(row, columns)
			testdb.Insert(t, conn, "product_builds", row)
		}
	}
	staff := func(confirmed any) func(t *testing.T, e *testEnv, conn *sql.DB) {
		return func(t *testing.T, e *testEnv, conn *sql.DB) {
			mustExec(t, conn, "UPDATE users SET email = 'Staff@Gumroad.com', confirmed_at = ? WHERE id = ?", confirmed, sellerID)
		}
	}
	for _, c := range []struct {
		name   string
		build  map[string]any
		setup  []func(t *testing.T, e *testEnv, conn *sql.DB)
		player bool
	}{
		{name: "a free product's live build", build: map[string]any{"status": "live"}, setup: []func(*testing.T, *testEnv, *sql.DB){free}, player: true},
		{name: "a paid product's live build", build: map[string]any{"status": "live"}},
		{name: "a free product with a paid option's live build", build: map[string]any{"status": "live"},
			setup: []func(*testing.T, *testEnv, *sql.DB){free, func(t *testing.T, e *testEnv, conn *sql.DB) {
				testdb.Insert(t, conn, "variant_categories", map[string]any{"id": int64(1_799_421), "link_id": productID, "title": "Size"})
				testdb.Insert(t, conn, "base_variants", map[string]any{"id": int64(1_799_422), "type": "Variant", "variant_category_id": int64(1_799_421),
					"name": "Large", "price_difference_cents": 100, "created_at": testNow, "updated_at": testNow})
			}}},
		{name: "a paid product's chosen build", build: map[string]any{"status": "uploaded", "demo_selected_at": testNow}, player: true},
		// What buyers of a paid product get is never public.
		{name: "a paid product's chosen live build", build: map[string]any{"status": "live", "demo_selected_at": testNow}},
		{name: "a build whose site isn't unpacked", build: map[string]any{"status": "live", "site_unpacked_at": nil},
			setup: []func(*testing.T, *testEnv, *sql.DB){free}},
		{name: "a build that isn't live or chosen", build: map[string]any{"status": "superseded"}, setup: []func(*testing.T, *testEnv, *sql.DB){free}},
		{name: "an unproven seller", build: map[string]any{"status": "live"}, setup: []func(*testing.T, *testEnv, *sql.DB){free, recent}},
		{name: "a new account of confirmed staff", build: map[string]any{"status": "live"}, player: true,
			setup: []func(*testing.T, *testEnv, *sql.DB){free, recent, staff(testNow)}},
		{name: "a new account with an unconfirmed staff email", build: map[string]any{"status": "live"},
			setup: []func(*testing.T, *testEnv, *sql.DB){free, recent, staff(nil)}},
		// min_by takes the chosen build, and demo? alone decides; the live one never stands in.
		{name: "a chosen build without its site beside a live one", build: map[string]any{"status": "uploaded", "demo_selected_at": testNow,
			"site_unpacked_at": nil}, setup: []func(*testing.T, *testEnv, *sql.DB){free, second(map[string]any{"status": "live"})}},
		{name: "a chosen build numbered after a live one", build: map[string]any{"status": "live"}, player: true,
			setup: []func(*testing.T, *testEnv, *sql.DB){second(map[string]any{"status": "uploaded", "demo_selected_at": testNow})}},
		{name: "a new seller with a paid sale", build: map[string]any{"status": "live"}, player: true,
			setup: []func(*testing.T, *testEnv, *sql.DB){free, recent, func(t *testing.T, e *testEnv, conn *sql.DB) {
				testdb.Insert(t, conn, "purchases", map[string]any{"id": int64(1_799_411), "seller_id": sellerID, "link_id": productID,
					"purchase_state": "successful", "price_cents": 100, "quantity": 1, "created_at": testNow, "updated_at": testNow})
			}}},
		{name: "a suspended seller", build: map[string]any{"status": "live"},
			setup: []func(*testing.T, *testEnv, *sql.DB){free, func(t *testing.T, e *testEnv, conn *sql.DB) {
				mustExec(t, conn, "UPDATE users SET user_risk_state = 'suspended_for_fraud' WHERE id = ?", sellerID)
			}}},
		{name: "the player flag off", build: map[string]any{"status": "live"},
			setup: []func(*testing.T, *testEnv, *sql.DB){free, func(t *testing.T, e *testEnv, conn *sql.DB) {
				e.redis.HDel("product_build_player", "boolean")
			}}},
	} {
		t.Run(c.name, func(t *testing.T) {
			e := newTestEnv(t)
			conn := testdb.Open(t)
			addCover(t, true)
			e.redis.HSet("product_build_demo", "boolean", "true")
			e.redis.HSet("product_build_player", "boolean", "true")
			mustExec(t, conn, "UPDATE users SET created_at = ? WHERE id = ?", time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC), sellerID)
			row := map[string]any{"id": buildID, "product_id": productID, "public_id": "gowebbuild1", "number": 1,
				"source_url": "https://example.com/build.zip", "storage_key": "builds/1", "byte_size": 1, "site_unpacked_at": testNow,
				"created_at": testNow, "updated_at": testNow}
			maps.Copy(row, c.build)
			testdb.Insert(t, conn, "product_builds", row)
			for _, setup := range c.setup {
				setup(t, e, conn)
			}
			body := e.render(t, nil, "")
			wants := []string{`<meta property="twitter:card" content="summary_large_image"`}
			if c.player {
				wants = []string{
					`<meta property="twitter:card" content="player" inertia="meta-property-twitter-card">`,
					`<meta property="twitter:image" content="` + retina + `" inertia="meta-property-twitter-image">`,
					`<meta property="twitter:player" content="https://gumroad.com/demo/` + e.ids.Encrypt(productID) + `" inertia="meta-property-twitter-player">`,
					`<meta property="twitter:player:width" content="640" inertia="meta-property-twitter-player-width">`,
					`{"tagName":"meta","headKey":"meta-property-twitter-player-height","property":"twitter:player:height","content":480}`,
				}
			}
			for _, want := range wants {
				if !strings.Contains(body, want) {
					t.Errorf("want %s", want)
				}
			}
		})
	}
}

// The custom HTML wrapper writes the same card as plain tags.
func TestCustomHTMLWithAProductBuildsDemo(t *testing.T) {
	e := newTestEnv(t)
	conn := testdb.Open(t)
	addCover(t, true)
	customHTML(t, e, conn)
	e.redis.HSet("product_build_demo", "boolean", "true")
	e.redis.HSet("product_build_player", "boolean", "true")
	mustExec(t, conn, "UPDATE users SET created_at = ? WHERE id = ?", time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC), sellerID)
	mustExec(t, conn, "UPDATE links SET price_cents = 0 WHERE id = ?", productID)
	mustExec(t, conn, "UPDATE prices SET price_cents = 0 WHERE id = ?", priceID)
	testdb.Insert(t, conn, "product_builds", map[string]any{"id": int64(1_799_401), "product_id": productID, "public_id": "gowebbuild1",
		"number": 1, "status": "live", "source_url": "https://example.com/build.zip", "storage_key": "builds/1", "byte_size": 1,
		"site_unpacked_at": testNow, "created_at": testNow, "updated_at": testNow})
	w := e.get(host, "/l/guide", nil)
	want := `<meta property="twitter:card" content="player">` + "\n    " +
		`<meta property="twitter:image" content="https://public-files.gumroad.com/covers/retina">` + "\n    " +
		`<meta property="twitter:player" content="https://gumroad.com/demo/` + e.ids.Encrypt(productID) + `">` + "\n    " +
		`<meta property="twitter:player:width" content="640">` + "\n    " +
		`<meta property="twitter:player:height" content="480">`
	if e.railsHit != nil || !strings.Contains(w.Body.String(), want) {
		t.Errorf("%d %q, rails %v", w.Code, w.Header().Get("X-Go-Web-Fallback"), e.railsHit != nil)
	}
}
