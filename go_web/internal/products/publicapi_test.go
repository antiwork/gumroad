package products

import (
	"net/http"
	"strings"
	"testing"

	"github.com/antiwork/gumroad/go_web/internal/session/testdb"
)

// GET /l/:id.json is ProductPresenter::PublicApiProps: the cheapest variant's price, and the
// top reviews the page shows, newest first among equal ratings.
func TestTheProductJSON(t *testing.T) {
	e := newTestEnv(t)
	conn := testdb.Open(t)
	const category = int64(1_795_501)
	mustExec(t, conn, "UPDATE links SET customizable_price = 1, suggested_price_cents = 700, flags = flags | ? WHERE id = ?",
		productDisplayReviews, productID)
	testdb.Insert(t, conn, "variant_categories", map[string]any{"id": category, "link_id": productID, "title": "Size"})
	for _, v := range []struct {
		id, difference int64
		deleted        any
	}{{1_795_511, 300, nil}, {1_795_512, 100, nil}, {1_795_513, 0, testNow}} {
		testdb.Insert(t, conn, "base_variants", map[string]any{"id": v.id, "type": "Variant", "variant_category_id": category,
			"name": "V", "price_difference_cents": v.difference, "deleted_at": v.deleted, "created_at": testNow, "updated_at": testNow})
	}
	addBuyer(t, conn, nil)
	for i, r := range []struct {
		rating    int
		message   any
		anonymous any
		at        int
		deleted   any
	}{
		{5, "Great", nil, 1, nil},
		{5, "Fine", true, 2, nil},
		{4, nil, nil, 3, nil},
		{5, "Gone", nil, 4, testNow},
	} {
		purchase, review := int64(1_795_601+i), int64(1_795_701+i)
		addPurchase(t, conn, purchase, map[string]any{"purchaser_id": buyerID})
		testdb.Insert(t, conn, "product_reviews", map[string]any{"id": review, "link_id": productID, "purchase_id": purchase,
			"rating": r.rating, "message": r.message, "anonymous": r.anonymous, "deleted_at": r.deleted,
			"created_at": testNow.AddDate(0, 0, r.at), "updated_at": testNow})
	}
	testdb.Insert(t, conn, "product_review_responses", map[string]any{"id": int64(1_795_801), "user_id": sellerID,
		"product_review_id": int64(1_795_702), "message": "Thanks", "created_at": testNow, "updated_at": testNow})

	w := e.get(host, "/l/guide.json", nil)
	if w.Code != http.StatusOK || e.railsHit != nil || w.Header().Get("Content-Type") != "application/json; charset=utf-8" ||
		w.Header().Get("Vary") != "Origin" || w.Header().Get("X-Robots-Tag") != "" ||
		strings.Contains(w.Header().Get("Content-Security-Policy"), "nonce") {
		t.Fatalf("%d %q %v", w.Code, w.Header().Get("X-Go-Web-Fallback"), w.Header())
	}
	avatar := "https://assets.gumroad.com/images/gumroad-default-avatar-5.png"
	want := `{"api_version":1,"id":"` + e.ids.Encrypt(productID) + `","permalink":"guide","name":"Guide \u003c1\u003e",` +
		`"native_type":"digital","url":"https://gowebproductseller.gumroad.com/l/guide","thumbnail_url":null,` +
		`"created_at":"2026-11-06T12:00:00Z","updated_at":"2026-11-06T12:00:00Z","seller":{"id":"1790001","name":"Seller",` +
		`"avatar_url":"` + avatar + `","profile_url":"https://gowebproductseller.gumroad.com/","is_verified":false},` +
		`"price_cents":500,"currency_code":"usd","price_formatted":"$6+","is_pay_what_you_want":true,"suggested_price_cents":700,`
	if body := w.Body.String(); !strings.HasPrefix(body, want) {
		t.Errorf("want prefix %s\nin %s", want, body)
	}
	reviews := `"reviews":[{"id":"` + e.ids.Encrypt(1_795_702) + `","rating":5,"message":"Fine","rater":{"avatar_url":"` + avatar +
		`","name":"Anonymous"},"created_at":"2026-11-08T12:00:00Z","response":{"message":"Thanks"}},{"id":"` + e.ids.Encrypt(1_795_701) +
		`","rating":5,"message":"Great","rater":{"avatar_url":"` + avatar + `","name":"Buyer"},"created_at":"2026-11-07T12:00:00Z","response":null}],`
	if body := w.Body.String(); !strings.Contains(body, reviews) {
		t.Errorf("want %s\nin %s", reviews, body)
	}
}

// The permalink redirect keeps the format, and a product custom HTML wraps stays JSON.
func TestTheProductJSONFilters(t *testing.T) {
	t.Run("redirect", func(t *testing.T) {
		e := newTestEnv(t)
		w := e.get(host, "/l/gowebp1.json?a=1", nil)
		if w.Code != http.StatusMovedPermanently || w.Header().Get("Location") != "https://"+host+"/l/guide.json?a=1" {
			t.Errorf("%d %q", w.Code, w.Header().Get("Location"))
		}
	})
	t.Run("custom html", func(t *testing.T) {
		e := newTestEnv(t)
		customHTML(t, e, testdb.Open(t))
		w := e.get(host, "/l/guide.json", nil)
		if w.Code != http.StatusOK || w.Header().Get("Content-Type") != "application/json; charset=utf-8" {
			t.Errorf("%d %q", w.Code, w.Header().Get("Content-Type"))
		}
	})
	t.Run("not for sale", func(t *testing.T) {
		e := newTestEnv(t)
		mustExec(t, testdb.Open(t), "UPDATE links SET purchase_disabled_at = ? WHERE id = ?", testNow, productID)
		w := e.get(host, "/l/guide.json", nil)
		if w.Code != http.StatusOK || w.Header().Get("X-Robots-Tag") != "noindex" || !strings.Contains(w.Body.String(), `"is_published":false`) {
			t.Errorf("%d %q %s", w.Code, w.Header().Get("X-Robots-Tag"), w.Body.String())
		}
	})
	for _, c := range []struct{ target, reason string }{
		{"/l/guide.xml", "format"},
		// No route takes an empty format.
		{"/l/guide.", "format"},
		{"/l/guide%2Ejson", "permalink"},
		{"/l/guide.json?wanted=true", "wanted json"},
	} {
		t.Run(c.target, func(t *testing.T) {
			e := newTestEnv(t)
			e.renderAt(t, c.target, nil, c.reason)
		})
	}
}

// A Discover click on the JSON is recorded as on the page, as the signed-in visitor's.
func TestAProductJSONDiscoverClick(t *testing.T) {
	e := newTestEnv(t)
	conn := testdb.Open(t)
	e.redis.HSet("store_discover_searches", "boolean", "true")
	t.Cleanup(func() { conn.Exec("DELETE FROM discover_searches WHERE clicked_resource_id = ?", productID) })
	addBuyer(t, conn, nil)
	headers := e.signedIn(buyerID, nil)
	headers["Cookie"] += "; _gumroad_guid=guid-json"
	if w := e.get(host, "/l/guide.json?recommended_by=search", headers); w.Code != http.StatusOK || e.railsHit != nil {
		t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
	var userID int64
	if err := conn.QueryRow("SELECT user_id FROM discover_searches WHERE clicked_resource_id = ? AND browser_guid = 'guid-json'",
		productID).Scan(&userID); err != nil || userID != buyerID {
		t.Errorf("%d %v", userID, err)
	}
}
