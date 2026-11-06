package products

import (
	"database/sql"
	"html"
	"net/http"
	"net/http/httptest"
	"reflect"
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

// layout and recommended_by values this port leaves to Rails, and bare keys it doesn't.
func TestALayoutOrRecommendationParam(t *testing.T) {
	for query, reason := range map[string]string{
		"?layout=embed":                  "param layout",
		"?layout=profile&embed=true":     "layout with iframe",
		"?layout=discover&overlay=true":  "layout with iframe",
		"?recommended_by=search":         "",
		"?recommended_by=discover":       "",
		"?recommended_by[]=wishlist":     "param recommended_by",
		"?layout=profile&recommended_by": "",
		"?layout":                        "",
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

// layout=discover renders the page in Discover's component with the product's taxonomy path and
// Rails' cached nav, and no storefront catalog; a visitor whose cart or purchases would reorder
// the nav goes to Rails, as does a nav Rails hasn't cached.
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
	for _, c := range []struct {
		name, reason string
		prepare      func(t *testing.T, e *testEnv, conn *sql.DB) map[string]string
	}{
		{"an uncached nav", "taxonomies for nav", func(t *testing.T, e *testEnv, conn *sql.DB) map[string]string { return nil }},
		{"a signed-in visitor", "discover recommendations", func(t *testing.T, e *testEnv, conn *sql.DB) map[string]string {
			e.cache.values["taxonomies_for_nav"] = nav
			addBuyer(t, conn, nil)
			return e.signedIn(buyerID, nil)
		}},
		{"a guest cart", "discover recommendations", func(t *testing.T, e *testEnv, conn *sql.DB) map[string]string {
			e.cache.values["taxonomies_for_nav"] = nav
			testdb.Insert(t, conn, "carts", map[string]any{"id": int64(1_795_921), "browser_guid": "guid-cart", "created_at": testNow, "updated_at": testNow})
			testdb.Insert(t, conn, "cart_products", map[string]any{"id": int64(1_795_922), "cart_id": int64(1_795_921), "product_id": productID,
				"price": 500, "quantity": 1, "referrer": "", "created_at": testNow, "updated_at": testNow})
			return map[string]string{"Cookie": "_gumroad_guid=guid-cart"}
		}},
	} {
		t.Run(c.name, func(t *testing.T) {
			e := newTestEnv(t)
			conn := testdb.Open(t)
			setup(t, e, conn)
			headers := c.prepare(t, e, conn)
			if headers == nil {
				headers = map[string]string{}
			}
			headers["X-Go-Web-Dry-Run"] = e.dryRun(host, "/l/guide?layout=discover", testNow)["X-Go-Web-Dry-Run"]
			if w := e.get(host, "/l/guide?layout=discover", headers); w.Code != http.StatusNoContent || w.Header().Get("X-Go-Web-Fallback") != c.reason {
				t.Errorf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
			}
		})
	}
}
