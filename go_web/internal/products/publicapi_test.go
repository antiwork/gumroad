package products

import (
	"database/sql"
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
}

// Every format but the page's goes through show's filters: format.json's payload, format.any's
// e404 in the exceptions app's format, and the catch-all's for a path no /l/ route takes.
func TestTheProductJSONRoutes(t *testing.T) {
	notFound := `{"status":404,"error":"Not Found"}`
	for _, c := range []struct {
		target, contentType, body string
		status                    int
	}{
		{"/l/guide.xml", "application/xml; charset=utf-8", "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<hash>\n  <status type=\"integer\">404</status>\n  <error>Not Found</error>\n</hash>\n", 404},
		{"/l/guide.yml", "application/x-yaml; charset=utf-8", "---\n:status: 404\n:error: Not Found\n", 404},
		{"/l/guide.JSON", "text/html; charset=utf-8", "Page not found (404)", 404},
		{"/l/guide/CO.DE", "text/html; charset=utf-8", "Page not found (404)", 404},
		{"/l/guide.", "text/html; charset=utf-8", "Page not found (404)", 404},
		{"/l/gu.ide.json", "application/json; charset=utf-8", notFound, 404},
		{"/l/guide/a/b.json", "application/json; charset=utf-8", notFound, 404},
		// Rack::UTF8Sanitizer decodes an escaped dot before routing.
		{"/l/guide%2Ejson", "application/json; charset=utf-8", `"permalink":"guide"`, 200},
		{"/l/guide/CODE.json", "application/json; charset=utf-8", `"permalink":"guide"`, 200},
		{"/l/guide.html", "text/html; charset=utf-8", `&quot;url&quot;:&quot;/l/guide.html&quot;`, 200},
	} {
		t.Run(c.target, func(t *testing.T) {
			e := newTestEnv(t)
			w := e.get(host, c.target, nil)
			if w.Code != c.status || e.railsHit != nil || w.Header().Get("Content-Type") != c.contentType || !strings.Contains(w.Body.String(), c.body) {
				t.Fatalf("%d %q %q %.300s", w.Code, w.Header().Get("X-Go-Web-Fallback"), w.Header().Get("Content-Type"), w.Body.String())
			}
			if c.status == 404 && w.Header().Get("Set-Cookie") != "" {
				t.Errorf("cookies %q", w.Header().Values("Set-Cookie"))
			}
			if strings.Contains(c.target, "CODE") && w.Header().Get("X-Robots-Tag") != "noindex" {
				t.Errorf("robots %q", w.Header().Get("X-Robots-Tag"))
			}
		})
	}
	t.Run("redirect keeps the format", func(t *testing.T) {
		e := newTestEnv(t)
		if w := e.get(host, "/l/GOWEBP1.xml", nil); w.Code != http.StatusMovedPermanently || w.Header().Get("Location") != "https://"+host+"/l/guide.xml" {
			t.Errorf("%d %q", w.Code, w.Header().Get("Location"))
		}
	})
	t.Run("wanted", func(t *testing.T) {
		e := newTestEnv(t)
		w := e.get(host, "/l/guide.json?wanted=true", nil)
		want := "https://gumroad.com/checkout?action=show&controller=links&format=json&id=guide&price=500&product=gowebp1&rent=false&wanted=true"
		if w.Code != http.StatusFound || w.Header().Get("Location") != want {
			t.Errorf("%d %q", w.Code, w.Header().Get("Location"))
		}
	})
	t.Run("no currency", func(t *testing.T) {
		e := newTestEnv(t)
		mustExec(t, testdb.Open(t), "UPDATE links SET price_currency_type = NULL WHERE id = ?", productID)
		w := e.get(host, "/l/guide.json", nil)
		if w.Code != http.StatusInternalServerError || w.Body.String() != `{"status":500,"error":"Internal Server Error"}` ||
			w.Header().Get("Set-Cookie") != "" {
			t.Errorf("%d %q %v", w.Code, w.Body.String(), w.Header())
		}
	})
}

// A membership's price is its cheapest offered tier price at that price's recurrence, with a +
// for several tiers or prices, or a pay-what-you-want tier.
func TestAProductJSONMembershipPrice(t *testing.T) {
	const category, basic, pro = int64(1_795_521), int64(1_795_522), int64(1_795_523)
	setup := func(t *testing.T, conn *sql.DB, tiers map[int64][][2]any) {
		mustExec(t, conn, "UPDATE links SET flags = flags | ? | ?, subscription_duration = 0, native_type = 'membership' WHERE id = ?",
			productIsRecurringBilling, productIsTieredMembership, productID)
		mustExec(t, conn, "UPDATE prices SET price_cents = 0, recurrence = 'monthly' WHERE id = ?", priceID)
		testdb.Insert(t, conn, "variant_categories", map[string]any{"id": category, "link_id": productID, "title": "Tier"})
		for id, prices := range tiers {
			testdb.Insert(t, conn, "base_variants", map[string]any{"id": id, "type": "Variant", "variant_category_id": category, "name": "T",
				"position_in_category": id, "created_at": testNow, "updated_at": testNow})
			for i, pr := range prices {
				testdb.Insert(t, conn, "prices", map[string]any{"id": id + int64(i+1)*100, "variant_id": id, "price_cents": pr[0],
					"currency": "usd", "recurrence": pr[1], "created_at": testNow, "updated_at": testNow})
			}
		}
	}
	for _, c := range []struct {
		name  string
		tiers map[int64][][2]any
		want  string
	}{
		{"two tiers", map[int64][][2]any{basic: {{900, "yearly"}, {300, "quarterly"}}, pro: {{500, "monthly"}}}, `"price_formatted":"$3+ every 3 months"`},
		{"one tier, one price", map[int64][][2]any{basic: {{300, "monthly"}}}, `"price_formatted":"$3 a month"`},
		{"one tier, two prices", map[int64][][2]any{basic: {{300, "monthly"}, {3000, "yearly"}}}, `"price_formatted":"$3+ a month"`},
		{"no tiers", nil, `"price_formatted":"$0 a month"`},
	} {
		t.Run(c.name, func(t *testing.T) {
			e := newTestEnv(t)
			setup(t, testdb.Open(t), c.tiers)
			if w := e.get(host, "/l/guide.json", nil); w.Code != http.StatusOK || !strings.Contains(w.Body.String(), c.want) {
				t.Errorf("%d %q %.400s", w.Code, w.Header().Get("X-Go-Web-Fallback"), w.Body.String())
			}
		})
	}
}

// displayPrice is MoneyFormatter's output, as production's Ruby answered for each.
func TestDisplayPrice(t *testing.T) {
	for _, c := range []struct {
		cents    int64
		currency string
		want     string
	}{
		{-500, "usd", "$-5"}, {-1, "usd", "$-0.01"}, {-99, "usd", "$-0.99"}, {-123456, "usd", "$-1,234.56"},
		{-500, "eur", "€-5"}, {-500, "jpy", "¥-500"}, {500, "xyz", "5 XYZ"}, {-500, "xyz", "-5 XYZ"},
		{123456, "xyz", "1,234.56 XYZ"}, {500, "", "5"}, {99, "xyz", "0.99 XYZ"}, {500, "sek", "5 kr"}, {99, "usd", "99¢"},
		{-500, "sek", "-5 kr"}, {-123456, "vnd", "-123,456 ₫"}, {-500, "chf", "CHF -5"}, {-123456, "inr", "₹-1,234.56"},
	} {
		if got, ok := displayPrice(c.cents, c.currency); !ok || got != c.want {
			t.Errorf("%d %q: %q %v", c.cents, c.currency, got, ok)
		}
	}
	if _, ok := displayPrice(500, "btc"); ok {
		t.Error("btc formatted")
	}
}

// The reviews' shapes as Rails loads them: a review repeated for each approved video, the
// first response, and a 500 where product_review_props raises.
func TestTheProductJSONReviewShapes(t *testing.T) {
	const review, video = int64(1_795_751), int64(1_795_761)
	setup := func(t *testing.T, conn *sql.DB, purchase any) {
		mustExec(t, conn, "UPDATE links SET flags = flags | ? WHERE id = ?", productDisplayReviews, productID)
		addPurchase(t, conn, 1_795_741, nil)
		testdb.Insert(t, conn, "product_reviews", map[string]any{"id": review, "link_id": productID, "purchase_id": purchase,
			"rating": 5, "message": "Good", "created_at": testNow, "updated_at": testNow})
	}
	videoRow := func(t *testing.T, conn *sql.DB, id int64, file bool) {
		testdb.Insert(t, conn, "product_review_videos", map[string]any{"id": id, "product_review_id": review, "approval_status": "approved",
			"created_at": testNow, "updated_at": testNow})
		if file {
			testdb.Insert(t, conn, "video_files", map[string]any{"id": id, "record_type": "ProductReviewVideo", "record_id": id,
				"user_id": sellerID, "url": "https://s3.amazonaws.com/gumroad/v.mp4", "created_at": testNow, "updated_at": testNow})
		}
	}
	reviewJSON := func(e *testEnv, response string) string {
		return `{"id":"` + e.ids.Encrypt(review) + `","rating":5,"message":"Good","rater":{"avatar_url":` +
			`"https://assets.gumroad.com/images/gumroad-default-avatar-5.png","name":"Anonymous"},"created_at":"2026-11-06T12:00:00Z","response":` + response + `}`
	}
	t.Run("two approved videos", func(t *testing.T) {
		e := newTestEnv(t)
		conn := testdb.Open(t)
		setup(t, conn, int64(1_795_741))
		videoRow(t, conn, video, true)
		videoRow(t, conn, video+1, true)
		r := reviewJSON(e, "null")
		if w := e.get(host, "/l/guide.json", nil); w.Code != http.StatusOK || !strings.Contains(w.Body.String(), `"reviews":[`+r+`,`+r+`]`) {
			t.Errorf("%d %q %s", w.Code, w.Header().Get("X-Go-Web-Fallback"), w.Body.String())
		}
	})
	t.Run("two responses", func(t *testing.T) {
		e := newTestEnv(t)
		conn := testdb.Open(t)
		setup(t, conn, int64(1_795_741))
		for i, m := range []string{"First", "Second"} {
			testdb.Insert(t, conn, "product_review_responses", map[string]any{"id": int64(1_795_771 + i), "user_id": sellerID,
				"product_review_id": review, "message": m, "created_at": testNow, "updated_at": testNow})
		}
		if w := e.get(host, "/l/guide.json", nil); w.Code != http.StatusOK || !strings.Contains(w.Body.String(), reviewJSON(e, `{"message":"First"}`)) {
			t.Errorf("%d %s", w.Code, w.Body.String())
		}
	})
	for _, c := range []struct {
		name    string
		prepare func(t *testing.T, conn *sql.DB)
	}{
		{"a video without its file", func(t *testing.T, conn *sql.DB) {
			setup(t, conn, int64(1_795_741))
			videoRow(t, conn, video, false)
		}},
		{"no purchase", func(t *testing.T, conn *sql.DB) { setup(t, conn, nil) }},
		{"a missing purchase", func(t *testing.T, conn *sql.DB) { setup(t, conn, int64(1_795_749)) }},
	} {
		t.Run(c.name, func(t *testing.T) {
			e := newTestEnv(t)
			c.prepare(t, testdb.Open(t))
			if w := e.get(host, "/l/guide.json", nil); w.Code != http.StatusInternalServerError || w.Body.String() != `{"status":500,"error":"Internal Server Error"}` {
				t.Errorf("%d %q %s", w.Code, w.Header().Get("X-Go-Web-Fallback"), w.Body.String())
			}
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
