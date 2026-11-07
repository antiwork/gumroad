package products

import (
	"database/sql"
	"html"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/elastic"
	"github.com/antiwork/gumroad/go_web/internal/railscache"
	"github.com/antiwork/gumroad/go_web/internal/session/testdb"
)

// layout=profile renders the product page props in the profile component, without the
// storefront's catalog unless the seller has one.
func TestTheProfileLayout(t *testing.T) {
	e := newTestEnv(t)
	testdb.Open(t)
	plain := e.get(host, "/l/guide", nil)
	profile := e.get(host, "/l/guide?layout=profile", nil)
	if plain.Code != http.StatusOK || profile.Code != http.StatusOK || e.railsHit != nil {
		t.Fatalf("%d %d %q", plain.Code, profile.Code, profile.Header().Get("X-Go-Web-Fallback"))
	}
	want, got := componentProps(t, plain.Body.String(), productComponent), componentProps(t, profile.Body.String(), storefrontComponent)
	// Each request has its own session, and with it its own CSRF token.
	for _, props := range []map[string]any{want, got} {
		delete(props, "authenticity_token")
		delete(props, "csp_nonce")
		for _, tag := range props["_inertia_meta"].([]any) {
			if tag := tag.(map[string]any); tag["headKey"] == "meta-name-csrf-token" {
				tag["content"] = ""
			}
		}
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("profile props %v\nwant %v", got, want)
	}
}

// layout, recommended_by and query values this port leaves to Rails, and bare keys it doesn't.
func TestALayoutOrRecommendationParam(t *testing.T) {
	for query, reason := range map[string]string{
		"?layout=embed":                     "",
		"?layout=1%27+and+%22":              "",
		"?layout[]=profile":                 "param layout",
		"?layout=profile&embed=true":        "layout with iframe",
		"?layout=discover&overlay=true":     "layout with iframe",
		"?recommended_by=search":            "",
		"?recommended_by=discover":          "",
		"?recommended_by[]=wishlist":        "param recommended_by",
		"?layout=profile&recommended_by":    "",
		"?layout":                           "",
		"?query[]=pens":                     "param query",
		"?query=pens&recommended_by=search": "",
		"?query":                            "",
	} {
		t.Run(query, func(t *testing.T) {
			e := newTestEnv(t)
			testdb.Open(t)
			w := e.get(host, "/l/guide"+query, e.dryRun(host, "/l/guide"+query, testNow))
			if got := w.Header().Get("X-Go-Web-Fallback"); got != reason || reason == "" && w.Code != http.StatusOK {
				t.Errorf("%d %q, want %q", w.Code, got, reason)
			}
		})
	}
}

// A click from Discover is recorded as create_discover_search! records it, but not a bot's, and
// not in a dry run.
func TestADiscoverSearchClick(t *testing.T) {
	e := newTestEnv(t)
	conn := testdb.Open(t)
	e.redis.HSet("store_discover_searches", "boolean", "true")
	mustExec(t, conn, "UPDATE links SET taxonomy_id = ? WHERE id = ?", 1_795_901, productID)
	// The page writes these rows, so testdb doesn't clean them up.
	t.Cleanup(func() { conn.Exec("DELETE FROM discover_searches WHERE clicked_resource_id = ?", productID) })
	count := func() (n int) {
		if err := conn.QueryRow("SELECT COUNT(*) FROM discover_searches WHERE clicked_resource_id = ?", productID).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	path := "/l/guide?layout=profile&recommended_by=search"
	if w := e.get(host, path, map[string]string{"Cookie": "_gumroad_guid=guid-1"}); w.Code != http.StatusOK || e.railsHit != nil {
		t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
	var taxonomy int64
	var guid, resourceType string
	var userless, autocomplete, queryless bool
	if err := conn.QueryRow("SELECT taxonomy_id, browser_guid, clicked_resource_type, user_id IS NULL, autocomplete, query IS NULL"+
		" FROM discover_searches WHERE clicked_resource_id = ?", productID).Scan(&taxonomy, &guid, &resourceType, &userless, &autocomplete, &queryless); err != nil {
		t.Fatal(err)
	}
	if taxonomy != 1_795_901 || guid != "guid-1" || resourceType != "Link" || !userless || autocomplete || !queryless {
		t.Errorf("row %d %q %q %v %v %v", taxonomy, guid, resourceType, userless, autocomplete, queryless)
	}
	e.get(host, path, map[string]string{"Cookie": "_gumroad_guid=guid-2", "User-Agent": "Mozilla/5.0 (compatible; Googlebot/2.1)"})
	e.get(host, path, e.dryRun(host, path, testNow))
	if n := count(); n != 1 {
		t.Errorf("%d rows", n)
	}

	// A signed-in visitor's click is theirs.
	addBuyer(t, conn, nil)
	headers := e.signedIn(buyerID, nil)
	headers["Cookie"] += "; _gumroad_guid=guid-3"
	if w := e.get(host, path, headers); w.Code != http.StatusOK {
		t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
	var userID int64
	if err := conn.QueryRow("SELECT user_id FROM discover_searches WHERE browser_guid = 'guid-3'").Scan(&userID); err != nil || userID != buyerID {
		t.Errorf("user %d, %v", userID, err)
	}

	// Flipper rolls a blank guid as an actor, which this port doesn't.
	blank := e.dryRun(host, path, testNow.Add(time.Second))
	blank["Cookie"] = "_gumroad_guid="
	if w := e.get(host, path, blank); w.Header().Get("X-Go-Web-Fallback") != "blank guid" {
		t.Errorf("blank guid: %d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
}

// A click from a typed search records its query and a suggestion, an autocompleted or blank one
// no suggestion. A query past the column's 255 characters is truncated, as Rails' sql_mode does.
func TestADiscoverSearchClickWithAQuery(t *testing.T) {
	e := newTestEnv(t)
	conn := testdb.Open(t)
	e.redis.HSet("store_discover_searches", "boolean", "true")
	// Cleanups run last first, so the suggestions go while their searches remain.
	testdb.CleanupWhere(t, conn, "discover_searches", "clicked_resource_id = ?", productID)
	testdb.CleanupWhere(t, conn, "discover_search_suggestions",
		"discover_search_id IN (SELECT id FROM discover_searches WHERE clicked_resource_id = ?)", productID)
	for _, c := range []struct {
		guid, params            string
		query                   sql.NullString
		autocomplete, suggested bool
	}{
		{"guid-q1", "&query=pen+set", sql.NullString{String: "pen set", Valid: true}, false, true},
		{"guid-q2", "&query=pen+set&autocomplete=true", sql.NullString{String: "pen set", Valid: true}, true, false},
		{"guid-q3", "&query=pen&autocomplete[]=true", sql.NullString{String: "pen", Valid: true}, false, true},
		{"guid-q4", "&query=+", sql.NullString{String: " ", Valid: true}, false, false},
		{"guid-q5", "&query", sql.NullString{}, false, false},
		{"guid-q6", "&query=" + strings.Repeat("%C3%A9", 256), sql.NullString{String: strings.Repeat("é", 255), Valid: true}, false, true},
	} {
		path := "/l/guide?recommended_by=search" + c.params
		if w := e.get(host, path, map[string]string{"Cookie": "_gumroad_guid=" + c.guid}); w.Code != http.StatusOK || e.railsHit != nil {
			t.Fatalf("%s: %d %q", c.guid, w.Code, w.Header().Get("X-Go-Web-Fallback"))
		}
		var query sql.NullString
		var autocomplete bool
		var suggestions int
		if err := conn.QueryRow("SELECT discover_searches.query, discover_searches.autocomplete, COUNT(discover_search_suggestions.id)"+
			" FROM discover_searches LEFT JOIN discover_search_suggestions ON discover_search_suggestions.discover_search_id = discover_searches.id"+
			" AND discover_search_suggestions.deleted_at IS NULL WHERE discover_searches.browser_guid = ? GROUP BY discover_searches.id", c.guid).
			Scan(&query, &autocomplete, &suggestions); err != nil {
			t.Fatal(err)
		}
		if query != c.query || autocomplete != c.autocomplete || (suggestions == 1) != c.suggested {
			t.Errorf("%s: %v %v %d", c.guid, query, autocomplete, suggestions)
		}
	}
}

// layout=discover renders the page in Discover's component with the product's taxonomy path and
// Rails' cached nav, and no storefront catalog; a nav Rails hasn't cached goes to Rails.
func TestTheDiscoverLayout(t *testing.T) {
	nav := []any{
		railscache.Hash{{Key: railscache.Symbol("key"), Value: railscache.ASCII("1795911")}, {Key: railscache.Symbol("label"), Value: "Design"},
			{Key: railscache.Symbol("slug"), Value: "design"}, {Key: railscache.Symbol("parent_key"), Value: nil}},
		railscache.Hash{{Key: railscache.Symbol("key"), Value: railscache.ASCII("1795912")}, {Key: railscache.Symbol("label"), Value: nil},
			{Key: railscache.Symbol("slug"), Value: "icons"}, {Key: railscache.Symbol("parent_key"), Value: railscache.ASCII("1795911")}},
	}
	setup := func(t *testing.T, e *testEnv, conn *sql.DB) {
		// A storefront seller's, which has no catalog to search on Discover's layout.
		mustExec(t, conn, "UPDATE users SET flags = flags | ? WHERE id = ?", userProductPageStorefrontEnabled, sellerID)
		search := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			t.Errorf("searched %s", r.URL.Path)
			w.WriteHeader(http.StatusInternalServerError)
		}))
		t.Cleanup(search.Close)
		client, err := elastic.NewWithClient(search.URL, search.Client())
		if err != nil {
			t.Fatal(err)
		}
		e.config.Page.Search = client
		testdb.Insert(t, conn, "taxonomies", map[string]any{"id": int64(1_795_911), "slug": "design"})
		testdb.Insert(t, conn, "taxonomies", map[string]any{"id": int64(1_795_912), "parent_id": int64(1_795_911), "slug": "icons"})
		// The closure table has no id for testdb to clean up after.
		t.Cleanup(func() {
			conn.Exec("DELETE FROM taxonomy_hierarchies WHERE descendant_id IN (?, ?)", 1_795_911, 1_795_912)
		})
		for _, row := range [][3]int64{{1_795_911, 1_795_911, 0}, {1_795_912, 1_795_912, 0}, {1_795_911, 1_795_912, 1}} {
			mustExec(t, conn, "INSERT INTO taxonomy_hierarchies (ancestor_id, descendant_id, generations) VALUES (?, ?, ?)", row[0], row[1], row[2])
		}
		mustExec(t, conn, "UPDATE links SET taxonomy_id = ? WHERE id = ?", 1_795_912, productID)
	}
	t.Run("rendered", func(t *testing.T) {
		e := newTestEnv(t)
		conn := testdb.Open(t)
		setup(t, e, conn)
		e.cache.values["taxonomies_for_nav"] = nav
		w := e.get(host, "/l/guide?layout=discover", nil)
		if w.Code != http.StatusOK || e.railsHit != nil {
			t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
		}
		componentProps(t, w.Body.String(), discoverComponent)
		page := html.UnescapeString(dataPage.FindStringSubmatch(w.Body.String())[1])
		want := `"sections":[],"main_section_index":0,"taxonomy_path":"design/icons","taxonomies_for_nav":[` +
			`{"key":"1795911","label":"Design","slug":"design","parent_key":null},{"key":"1795912","label":null,"slug":"icons","parent_key":"1795911"}],"_inertia_meta"`
		if !strings.Contains(page, want) {
			t.Errorf("want %s\nin %s", want, page)
		}
	})
	t.Run("an uncached nav", func(t *testing.T) {
		e := newTestEnv(t)
		conn := testdb.Open(t)
		setup(t, e, conn)
		headers := e.dryRun(host, "/l/guide?layout=discover", testNow)
		if w := e.get(host, "/l/guide?layout=discover", headers); w.Code != http.StatusNoContent ||
			w.Header().Get("X-Go-Web-Fallback") != "taxonomies for nav" {
			t.Errorf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
		}
	})
}

// A visitor's cart or purchases reorder the Discover nav: the root taxonomies of the products
// bought with them come first, leaving out what they already have, what their bundles hold,
// and adult products.
func TestCuratedProductsReorderTheDiscoverNav(t *testing.T) {
	const (
		audio, music, rootless              = int64(1_795_913), int64(1_795_914), int64(1_795_915)
		loops, explicit, drums, bundle, odd = int64(1_795_931), int64(1_795_932), int64(1_795_934), int64(1_795_936), int64(1_795_937)
		beats, sketch                       = int64(1_795_938), int64(1_795_939)
	)
	entry := func(id int64, label any, slug string, parent any) railscache.Hash {
		return railscache.Hash{{Key: railscache.Symbol("key"), Value: railscache.ASCII(strconv.FormatInt(id, 10))},
			{Key: railscache.Symbol("label"), Value: label}, {Key: railscache.Symbol("slug"), Value: slug}, {Key: railscache.Symbol("parent_key"), Value: parent}}
	}
	setup := func(t *testing.T, e *testEnv, conn *sql.DB) {
		e.cache.values["taxonomies_for_nav"] = []any{entry(1_795_911, "Design", "design", nil),
			entry(1_795_912, nil, "icons", railscache.ASCII("1795911")), entry(audio, "Audio", "audio", nil), entry(music, "Music", "music", nil)}
		t.Cleanup(func() {
			conn.Exec("DELETE FROM taxonomy_hierarchies WHERE descendant_id IN (?, ?, ?, ?)", 1_795_911, 1_795_912, audio, music)
		})
		for _, root := range []struct {
			id   int64
			slug string
		}{{1_795_911, "design"}, {audio, "audio"}, {music, "music"}, {rootless, "rootless"}} {
			testdb.Insert(t, conn, "taxonomies", map[string]any{"id": root.id, "slug": root.slug})
			if root.id != rootless {
				mustExec(t, conn, "INSERT INTO taxonomy_hierarchies (ancestor_id, descendant_id, generations) VALUES (?, ?, 0)", root.id, root.id)
			}
		}
		testdb.Insert(t, conn, "taxonomies", map[string]any{"id": int64(1_795_912), "parent_id": int64(1_795_911), "slug": "icons"})
		mustExec(t, conn, "INSERT INTO taxonomy_hierarchies (ancestor_id, descendant_id, generations) VALUES (?, ?, 0), (?, ?, 1)",
			1_795_912, 1_795_912, 1_795_911, 1_795_912)
		for _, p := range []struct {
			id, taxonomy int64
			name         string
		}{{loops, audio, "Loops"}, {explicit, music, "NSFW sketches"}, {drums, music, "Drums"}, {bundle, music, "Kit"}, {odd, rootless, "Odd"},
			{beats, 1_795_912, "Beats"}, {sketch, 1_795_911, "Sketch"}} {
			testdb.Insert(t, conn, "links", map[string]any{"id": p.id, "user_id": sellerID, "name": p.name, "taxonomy_id": p.taxonomy,
				"unique_permalink": "gowebrec" + strconv.FormatInt(p.id%100, 10), "price_cents": 100, "created_at": testNow, "updated_at": testNow})
		}
		testdb.Insert(t, conn, "bundle_products", map[string]any{"id": int64(1_795_941), "bundle_id": bundle, "product_id": drums,
			"quantity": 1, "created_at": testNow, "updated_at": testNow})
	}
	related := func(t *testing.T, conn *sql.DB, counts string) {
		testdb.Insert(t, conn, "cached_sales_related_products_infos", map[string]any{"id": int64(1_795_951), "product_id": productID,
			"counts": counts, "created_at": testNow, "updated_at": testNow})
	}
	cart := func(t *testing.T, conn *sql.DB, products ...int64) map[string]string {
		testdb.Insert(t, conn, "carts", map[string]any{"id": int64(1_795_921), "browser_guid": "guid-cart", "created_at": testNow, "updated_at": testNow})
		for i, id := range products {
			testdb.Insert(t, conn, "cart_products", map[string]any{"id": int64(1_795_922 + i), "cart_id": int64(1_795_921), "product_id": id,
				"price": 500, "quantity": 1, "referrer": "", "created_at": testNow, "updated_at": testNow})
		}
		return map[string]string{"Cookie": "_gumroad_guid=guid-cart"}
	}
	// Drums sold most with the product but the bundle holds it, and the next is adult. Then
	// icons, audio and design itself: design scores first and keeps it.
	const counts = `{"1795934": 9, "1795932": 7, "1795938": 5, "1795931": 3, "1795939": 2}`
	const (
		design = `{"key":"1795911","label":"Design","slug":"design","parent_key":null}`
		icons  = `{"key":"1795912","label":null,"slug":"icons","parent_key":"1795911"}`
		audioJ = `{"key":"1795913","label":"Audio","slug":"audio","parent_key":null}`
		musicJ = `{"key":"1795914","label":"Music","slug":"music","parent_key":null}`
	)
	reordered := `"taxonomies_for_nav":[` + design + `,` + audioJ + `,` + icons + `,` + musicJ + `]`
	for _, c := range []struct {
		name    string
		prepare func(t *testing.T, e *testEnv, conn *sql.DB) map[string]string
		want    string
	}{
		{"a guest cart", func(t *testing.T, e *testEnv, conn *sql.DB) map[string]string {
			related(t, conn, counts)
			return cart(t, conn, productID, bundle)
		}, reordered},
		{"a signed-in visitor's purchases", func(t *testing.T, e *testEnv, conn *sql.DB) map[string]string {
			related(t, conn, counts)
			addBuyer(t, conn, nil)
			addPurchase(t, conn, 1_795_961, map[string]any{"purchaser_id": buyerID, "succeeded_at": testNow})
			addPurchase(t, conn, 1_795_962, map[string]any{"purchaser_id": buyerID, "succeeded_at": testNow, "link_id": bundle})
			return e.signedIn(buyerID, nil)
		}, reordered},
		// The limit leaves the bundle out of the seed, but not out of what's excluded.
		{"purchases past the associated ids limit", func(t *testing.T, e *testEnv, conn *sql.DB) map[string]string {
			e.redis.Set(associatedProductIDsLimitKey, "1")
			related(t, conn, counts)
			addBuyer(t, conn, nil)
			addPurchase(t, conn, 1_795_961, map[string]any{"purchaser_id": buyerID, "succeeded_at": testNow})
			addPurchase(t, conn, 1_795_962, map[string]any{"purchaser_id": buyerID, "succeeded_at": testNow.AddDate(0, 0, -1), "link_id": bundle})
			return e.signedIn(buyerID, nil)
		}, reordered},
		// Integer#+ raises on a String, and curated_products rescues it into no products.
		{"a count Ruby can't add", func(t *testing.T, e *testEnv, conn *sql.DB) map[string]string {
			related(t, conn, `{"1795931": 3, "1795938": "5"}`)
			return cart(t, conn, productID)
		}, `"taxonomies_for_nav":[` + design + `,` + icons + `,` + audioJ + `,` + musicJ + `]`},
	} {
		t.Run(c.name, func(t *testing.T) {
			e := newTestEnv(t)
			conn := testdb.Open(t)
			setup(t, e, conn)
			w := e.get(host, "/l/guide?layout=discover", c.prepare(t, e, conn))
			if w.Code != http.StatusOK || e.railsHit != nil {
				t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
			}
			if page := html.UnescapeString(dataPage.FindStringSubmatch(w.Body.String())[1]); !strings.Contains(page, c.want) {
				t.Errorf("want %s\nin %s", c.want, page)
			}
		})
	}
	// Sampling picks half of four or more at random; a dry run takes the first half, so a parity
	// run can make Rails' sample match. The product leads the cart, so every run reorders.
	t.Run("a dry run's sample", func(t *testing.T) {
		e := newTestEnv(t)
		conn := testdb.Open(t)
		setup(t, e, conn)
		related(t, conn, counts)
		cookie := cart(t, conn, productID, bundle, 1_795_971, 1_795_972)
		for i := range 10 {
			// Each signature is single-use.
			headers := e.dryRun(host, "/l/guide?layout=discover", testNow.Add(-time.Duration(i)*time.Second))
			headers["Cookie"] = cookie["Cookie"]
			w := e.get(host, "/l/guide?layout=discover", headers)
			if w.Code != http.StatusOK || e.railsHit != nil {
				t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
			}
			if page := html.UnescapeString(dataPage.FindStringSubmatch(w.Body.String())[1]); !strings.Contains(page, reordered) {
				t.Fatalf("want %s\nin %s", reordered, page)
			}
		}
	})
	t.Run("a curated taxonomy without a root", func(t *testing.T) {
		e := newTestEnv(t)
		conn := testdb.Open(t)
		setup(t, e, conn)
		related(t, conn, `{"1795937": 1}`)
		headers := cart(t, conn, productID)
		headers["X-Go-Web-Dry-Run"] = e.dryRun(host, "/l/guide?layout=discover", testNow)["X-Go-Web-Dry-Run"]
		if w := e.get(host, "/l/guide?layout=discover", headers); w.Code != http.StatusNoContent ||
			w.Header().Get("X-Go-Web-Fallback") != "curated taxonomy root" {
			t.Errorf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
		}
	})
}

// adultText tokenizes as AdultKeywordDetector does; each case is what production's Ruby answered.
func TestAdultText(t *testing.T) {
	for text, want := range map[string]bool{
		"nsfwé": false, "NSFWart": true, "ÉNSFW": false, "kinky": false, "kink!": true, "Breast\nInflation": true,
		"lewds": true, "abs  punch": true, "": false,
	} {
		if got := adultText(text); got != want {
			t.Errorf("%q: %v", text, got)
		}
	}
}
