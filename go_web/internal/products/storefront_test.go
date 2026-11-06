package products

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"html"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/elastic"
	"github.com/antiwork/gumroad/go_web/internal/session/testdb"
)

func TestTheStorefrontCatalog(t *testing.T) {
	const other, otherPrice, category = int64(1_792_101), int64(1_792_201), int64(1_792_301)
	// Link.search_options for the default products section as production builds it, with
	// Link.filetype_options' facet on the same query and one more hit for the tie check.
	wantBody := fmt.Sprintf(`{"query":{"bool":{"must":[{"terms":{"user_id":[%d]}},{"term":{"is_alive_on_profile":true}}]}},`+
		`"aggregations":{"tags.keyword":{"terms":{"field":"tags.keyword","size":200}},"filetypes.keyword":{"terms":{"field":"filetypes.keyword","size":8}}},`+
		`"sort":[{"created_at":{"order":"desc"}}],"size":10,"from":0,"_source":false,"track_total_hits":true}`, sellerID)
	var want any
	if err := json.Unmarshal([]byte(wantBody), &want); err != nil {
		t.Fatal(err)
	}
	var searches int
	var hits string
	search := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		searches++
		body, _ := io.ReadAll(r.Body)
		var got any
		if json.Unmarshal(body, &got) != nil || r.URL.Path != "/products/_search" || !reflect.DeepEqual(got, want) {
			t.Errorf("search %s %s", r.URL.Path, body)
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		io.WriteString(w, `{"hits":{"total":{"value":3,"relation":"eq"},"hits":`+hits+`},"aggregations":`+
			`{"tags.keyword":{"buckets":[{"key":"design","doc_count":2}]},"filetypes.keyword":{"buckets":[{"key":"pdf","doc_count":2}]}}}`)
	}))
	defer search.Close()
	failing := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		searches++
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer failing.Close()

	addOther := func(t *testing.T, conn *sql.DB, columns map[string]any) {
		row := map[string]any{"id": other, "user_id": sellerID, "name": "Other", "unique_permalink": "gowebp2", "price_cents": 300,
			"native_type": "ebook", "flags": productDisplayReviews, "created_at": testNow, "updated_at": testNow}
		for k, v := range columns {
			row[k] = v
		}
		testdb.Insert(t, conn, "links", row)
		testdb.Insert(t, conn, "prices", map[string]any{"id": otherPrice, "link_id": other, "price_cents": 300, "currency": "usd",
			"created_at": testNow, "updated_at": testNow})
	}
	// tieredOther makes the other product a monthly tiered membership: Basic at 300 a month,
	// and Pro at 100, pay what you want and closed to new buyers. Their yearly prices are lower.
	tieredOther := func(t *testing.T, conn *sql.DB) {
		addOther(t, conn, map[string]any{"flags": productIsRecurringBilling | productIsTieredMembership, "subscription_duration": 0,
			"native_type": "membership"})
		testdb.Insert(t, conn, "prices", map[string]any{"id": otherPrice + 1, "link_id": other, "price_cents": 0, "currency": "usd",
			"recurrence": "monthly", "created_at": testNow, "updated_at": testNow})
		testdb.Insert(t, conn, "variant_categories", map[string]any{"id": category, "link_id": other, "title": "Tier"})
		for i, tier := range []struct {
			name         string
			cents, flags int
			pwyw         bool
		}{{"Basic", 300, 0, false}, {"Pro", 100, 4, true}} {
			id := category + 1 + int64(i)
			testdb.Insert(t, conn, "base_variants", map[string]any{"id": id, "type": "Variant", "variant_category_id": category,
				"name": tier.name, "flags": tier.flags, "customizable_price": tier.pwyw, "sales_count_for_inventory_cache": 0,
				"created_at": testNow, "updated_at": testNow})
			for j, p := range []struct {
				cents      int
				recurrence string
			}{{tier.cents, "monthly"}, {50, "yearly"}} {
				testdb.Insert(t, conn, "prices", map[string]any{"id": id + 100*int64(j+1), "variant_id": id, "price_cents": p.cents,
					"currency": "usd", "recurrence": p.recurrence, "created_at": testNow, "updated_at": testNow})
			}
		}
	}
	section := func(e *testEnv, total int, products string) string {
		return fmt.Sprintf(`"sections":[{"id":"default-products","header":"More from Seller","type":"SellerProfileProductsSection",`+
			`"show_filters":false,"default_product_sort":"page_layout","search_results":{"total":%d,"tags_data":[{"key":"design","doc_count":2}],`+
			`"filetypes_data":[{"key":"pdf","doc_count":2}],"taxonomy_attributes_data":[],"products":[%s]},"exclude_ids":["%s"]}],"main_section_index":0`,
			total, products, e.ids.Encrypt(productID))
	}
	otherCard := func(e *testEnv) string {
		id := e.ids.Encrypt(other)
		return `{"id":"` + id + `","permalink":"gowebp2","name":"Other","seller":null,"ratings":{"count":3,"average":4.5},"thumbnail_url":null,` +
			`"native_type":"ebook","quantity_remaining":null,"is_sales_limited":false,"price_cents":400,"currency_code":"usd",` +
			`"buyer_currency_display":{"product_id":"` + id + `","buyer_currency_shown":"usd","product_currency":"usd","buyer_local_price_cents":null,` +
			`"rate":null,"display_mode":"default"},"is_pay_what_you_want":false,"url":"https://gowebproductseller.gumroad.com/l/gowebp2?layout=profile",` +
			`"duration_in_months":null,"recurrence":null}`
	}
	bothHits := fmt.Sprintf(`[{"_id":"%d","sort":[1762430000000]},{"_id":"%d","sort":[1762420000000]}]`, other, productID)

	for _, c := range []struct {
		name, reason, hits string
		server             *httptest.Server
		searched           int
		// cachesOnFallback is a search kept although the page goes to Rails.
		cachesOnFallback bool
		setup            func(t *testing.T, conn *sql.DB)
		// prepare sets flags and rates; headers go with the request.
		prepare func(e *testEnv)
		headers map[string]string
		want    func(e *testEnv) string
	}{
		{name: "the rest of the catalog, without this product", hits: bothHits, server: search, searched: 1,
			setup: func(t *testing.T, conn *sql.DB) {
				addOther(t, conn, nil)
				// lowest_variant_price_difference_cents skips a deleted variant.
				testdb.Insert(t, conn, "variant_categories", map[string]any{"id": category, "link_id": other, "title": "Size"})
				for i, diff := range []int{200, 100, 50} {
					v := map[string]any{"id": category + 1 + int64(i), "type": "Variant", "variant_category_id": category, "name": "V",
						"price_difference_cents": diff, "sales_count_for_inventory_cache": 0, "created_at": testNow, "updated_at": testNow}
					if diff == 50 {
						v["deleted_at"] = testNow
					}
					testdb.Insert(t, conn, "base_variants", v)
				}
				testdb.Insert(t, conn, "product_review_stats", map[string]any{"id": int64(1_792_401), "link_id": other, "reviews_count": 3,
					"average_rating": 4.5, "created_at": testNow, "updated_at": testNow})
			},
			want: func(e *testEnv) string { return section(e, 2, otherCard(e)) }},
		{name: "this product beyond the page still leaves the total", server: search, searched: 1,
			hits: fmt.Sprintf(`[{"_id":"%d","sort":[1762430000000]}]`, other),
			setup: func(t *testing.T, conn *sql.DB) {
				addOther(t, conn, map[string]any{"flags": 0, "custom_permalink": "other"})
			},
			want: func(e *testEnv) string {
				card := strings.Replace(otherCard(e), `"ratings":{"count":3,"average":4.5}`, `"ratings":null`, 1)
				card = strings.Replace(card, `"price_cents":400`, `"price_cents":300`, 1)
				return section(e, 2, strings.Replace(card, "/l/gowebp2?", "/l/other?", 1))
			}},
		{name: "a card's first image cover, past a video", server: search, searched: 1,
			hits: fmt.Sprintf(`[{"_id":"%d","sort":[1762430000000]}]`, other),
			setup: func(t *testing.T, conn *sql.DB) {
				addOther(t, conn, map[string]any{"flags": 0})
				blob := func(id int64, key, contentType, metadata string) {
					testdb.Insert(t, conn, "active_storage_blobs", map[string]any{"id": id, "key": key, "filename": "a.jpg",
						"content_type": contentType, "metadata": metadata, "service_name": "amazon_public", "byte_size": 1, "created_at": testNow})
				}
				attach := func(id int64, name, recordType string, recordID, blobID int64) {
					testdb.Insert(t, conn, "active_storage_attachments", map[string]any{"id": id, "name": name, "record_type": recordType,
						"record_id": recordID, "blob_id": blobID, "created_at": testNow})
				}
				for i, contentType := range []string{"video/mp4", "image/jpeg"} {
					id := int64(1_792_601 + i)
					testdb.Insert(t, conn, "asset_previews", map[string]any{"id": id, "link_id": other, "guid": fmt.Sprint("g", i),
						"position": i, "created_at": testNow, "updated_at": testNow})
					blob(1_792_701+int64(i), fmt.Sprint("covers/", i), contentType, `{"identified":true,"width":2000,"height":1000,"analyzed":true}`)
					attach(1_792_801+int64(i), "file", "AssetPreview", id, 1_792_701+int64(i))
				}
				// Ruby's digest of {format: "jpg", resize_to_limit: [1005, nil]}.
				testdb.Insert(t, conn, "active_storage_variant_records", map[string]any{"id": int64(1_792_901), "blob_id": int64(1_792_702),
					"variation_digest": "WX6OQ3hf/g9WoAI2n/sUdFF1vxA="})
				blob(1_792_703, "covers/retina", "image/jpeg", "{}")
				attach(1_792_803, "image", "ActiveStorage::VariantRecord", 1_792_901, 1_792_703)
			},
			want: func(e *testEnv) string {
				card := strings.Replace(otherCard(e), `"ratings":{"count":3,"average":4.5}`, `"ratings":null`, 1)
				card = strings.Replace(card, `"thumbnail_url":null`, `"thumbnail_url":"https://public-files.gumroad.com/covers/retina"`, 1)
				return section(e, 2, strings.Replace(card, `"price_cents":400`, `"price_cents":300`, 1))
			}},
		{name: "a card's uploaded thumbnail", server: search, searched: 1,
			hits: fmt.Sprintf(`[{"_id":"%d","sort":[1762430000000]}]`, other),
			setup: func(t *testing.T, conn *sql.DB) {
				addOther(t, conn, map[string]any{"flags": 0})
				testdb.Insert(t, conn, "thumbnails", map[string]any{"id": int64(1_792_951), "product_id": other, "guid": "t",
					"created_at": testNow, "updated_at": testNow})
				for i, key := range []string{"thumbnails/original", "thumbnails/600"} {
					testdb.Insert(t, conn, "active_storage_blobs", map[string]any{"id": int64(1_792_961 + i), "key": key, "filename": "t.png",
						"content_type": "image/png", "service_name": "amazon_public", "byte_size": 1, "created_at": testNow})
				}
				testdb.Insert(t, conn, "active_storage_attachments", map[string]any{"id": int64(1_792_971), "name": "file",
					"record_type": "Thumbnail", "record_id": int64(1_792_951), "blob_id": int64(1_792_961), "created_at": testNow})
				// Ruby's digest of {format: "png", resize_to_limit: [600, 600]}.
				testdb.Insert(t, conn, "active_storage_variant_records", map[string]any{"id": int64(1_792_981), "blob_id": int64(1_792_961),
					"variation_digest": "Qf43UUrCAHcLMQKl8+06HI/IH0c="})
				testdb.Insert(t, conn, "active_storage_attachments", map[string]any{"id": int64(1_792_972), "name": "image",
					"record_type": "ActiveStorage::VariantRecord", "record_id": int64(1_792_981), "blob_id": int64(1_792_962), "created_at": testNow})
			},
			want: func(e *testEnv) string {
				card := strings.Replace(otherCard(e), `"ratings":{"count":3,"average":4.5}`, `"ratings":null`, 1)
				card = strings.Replace(card, `"thumbnail_url":null`, `"thumbnail_url":"https://public-files.gumroad.com/thumbnails/600"`, 1)
				return section(e, 2, strings.Replace(card, `"price_cents":400`, `"price_cents":300`, 1))
			}},
		{name: "the default price recurrence of a one-time product", server: search, searched: 1,
			hits: fmt.Sprintf(`[{"_id":"%d","sort":[1762430000000]}]`, other),
			setup: func(t *testing.T, conn *sql.DB) {
				// subscription_duration is an enum column: 0 is monthly.
				addOther(t, conn, map[string]any{"flags": 0, "subscription_duration": 0})
				testdb.Insert(t, conn, "prices", map[string]any{"id": otherPrice + 1, "link_id": other, "price_cents": 300, "currency": "usd",
					"recurrence": "monthly", "created_at": testNow, "updated_at": testNow})
			},
			want: func(e *testEnv) string {
				card := strings.Replace(otherCard(e), `"ratings":{"count":3,"average":4.5}`, `"ratings":null`, 1)
				card = strings.Replace(card, `"recurrence":null`, `"recurrence":"monthly"`, 1)
				return section(e, 2, strings.Replace(card, `"price_cents":400`, `"price_cents":300`, 1))
			}},
		// A closed Pro tier is neither the price nor pay what you want.
		{name: "a tiered membership's card", server: search, searched: 1,
			hits:    fmt.Sprintf(`[{"_id":"%d","sort":[1762430000000]}]`, other),
			setup:   func(t *testing.T, conn *sql.DB) { tieredOther(t, conn) },
			prepare: func(e *testEnv) { e.redis.HSet("close_membership_tier_to_new_buyers", "boolean", "true") },
			want: func(e *testEnv) string {
				card := strings.Replace(otherCard(e), `"ratings":{"count":3,"average":4.5}`, `"ratings":null`, 1)
				card = strings.Replace(card, `"native_type":"ebook"`, `"native_type":"membership"`, 1)
				card = strings.Replace(card, `"recurrence":null`, `"recurrence":"monthly"`, 1)
				return section(e, 2, strings.Replace(card, `"price_cents":400`, `"price_cents":300`, 1))
			}},
		{name: "a tiered membership's card with every tier open", server: search, searched: 1,
			hits:  fmt.Sprintf(`[{"_id":"%d","sort":[1762430000000]}]`, other),
			setup: func(t *testing.T, conn *sql.DB) { tieredOther(t, conn) },
			want: func(e *testEnv) string {
				card := strings.Replace(otherCard(e), `"ratings":{"count":3,"average":4.5}`, `"ratings":null`, 1)
				card = strings.Replace(card, `"native_type":"ebook"`, `"native_type":"membership"`, 1)
				card = strings.Replace(card, `"recurrence":null`, `"recurrence":"monthly"`, 1)
				card = strings.Replace(card, `"is_pay_what_you_want":false`, `"is_pay_what_you_want":true`, 1)
				return section(e, 2, strings.Replace(card, `"price_cents":400`, `"price_cents":100`, 1))
			}},
		{name: "a legacy subscription's card", server: search, searched: 1,
			hits: fmt.Sprintf(`[{"_id":"%d","sort":[1762430000000]}]`, other),
			setup: func(t *testing.T, conn *sql.DB) {
				addOther(t, conn, map[string]any{"flags": productIsRecurringBilling, "subscription_duration": 0})
				for i, p := range []struct {
					cents      int
					recurrence string
				}{{500, "monthly"}, {4000, "yearly"}} {
					testdb.Insert(t, conn, "prices", map[string]any{"id": otherPrice + 1 + int64(i), "link_id": other, "price_cents": p.cents,
						"currency": "usd", "recurrence": p.recurrence, "created_at": testNow, "updated_at": testNow})
				}
			},
			want: func(e *testEnv) string {
				card := strings.Replace(otherCard(e), `"ratings":{"count":3,"average":4.5}`, `"ratings":null`, 1)
				card = strings.Replace(card, `"recurrence":null`, `"recurrence":"monthly"`, 1)
				return section(e, 2, strings.Replace(card, `"price_cents":400`, `"price_cents":500`, 1))
			}},
		{name: "a tiered membership without a duration", reason: "catalog subscription duration", hits: bothHits, server: search, searched: 1,
			setup: func(t *testing.T, conn *sql.DB) {
				tieredOther(t, conn)
				conn.Exec("UPDATE links SET subscription_duration = NULL WHERE id = ?", other)
			}},
		{name: "a membership card with a local price", reason: "catalog unquotable product", hits: bothHits, server: search, searched: 1,
			headers: eurCookie,
			setup: func(t *testing.T, conn *sql.DB) {
				addOther(t, conn, map[string]any{"flags": productIsRecurringBilling, "subscription_duration": 0})
			},
			prepare: func(e *testEnv) { e.localEUR("0.92345") }},
		{name: "a tie at the page's edge", reason: "catalog order", server: search, searched: 1,
			hits: func() string {
				var hs []string
				for i := range 10 {
					sort := 1762430000000 - i
					if i == 9 {
						sort++
					}
					hs = append(hs, fmt.Sprintf(`{"_id":"%d","sort":[%d]}`, 1_792_001+i, sort))
				}
				return "[" + strings.Join(hs, ",") + "]"
			}()},
		{name: "a sold-out product hidden", hits: bothHits, server: search, searched: 1,
			setup: func(t *testing.T, conn *sql.DB) {
				addOther(t, conn, map[string]any{"flags": productHideSoldOutVariants, "max_purchase_count": 0})
			},
			want: func(e *testEnv) string { return section(e, 1, "") }},
		{name: "nothing else listed", server: search,
			setup: func(t *testing.T, conn *sql.DB) {
				conn.Exec("UPDATE links SET flags = flags | ? WHERE id = ?", productArchived, productID)
			},
			want: func(*testEnv) string { return `"sections":[],"main_section_index":0` }},
		{name: "saved profile sections", reason: "storefront sections", server: search,
			setup: func(t *testing.T, conn *sql.DB) {
				testdb.Insert(t, conn, "seller_profile_sections", map[string]any{"id": int64(1_792_501), "seller_id": sellerID,
					"created_at": testNow, "updated_at": testNow})
			}},
		{name: "a card this port leaves to Rails", reason: "catalog default offer code", hits: bothHits, server: search, searched: 1,
			cachesOnFallback: true,
			setup: func(t *testing.T, conn *sql.DB) {
				addOther(t, conn, map[string]any{"default_offer_code_id": 1})
			}},
		{name: "the seller's auto-applied sale", reason: "catalog auto-apply", server: search,
			setup: func(t *testing.T, conn *sql.DB) {
				insertOfferCode(t, conn, 1_792_601, map[string]any{"code": "SALE", "amount_percentage": 10, "universal": true, "auto_apply": true})
			}},
		{name: "a hit with no row", reason: "catalog product missing", hits: bothHits, server: search, searched: 1},
		{name: "a failed search", reason: "catalog search", server: failing, searched: 1},
		{name: "no search client", reason: "storefront"},
	} {
		t.Run(c.name, func(t *testing.T) {
			searches, hits = 0, c.hits
			e := newTestEnv(t)
			conn := testdb.Open(t)
			conn.Exec("UPDATE users SET flags = flags | ? WHERE id = ?", userProductPageStorefrontEnabled, sellerID)
			if c.setup != nil {
				c.setup(t, conn)
			}
			if c.prepare != nil {
				c.prepare(e)
			}
			if c.server != nil {
				client, err := elastic.NewWithClient(c.server.URL, c.server.Client())
				if err != nil {
					t.Fatal(err)
				}
				e.config.Page.Search = client
			}
			w := e.get(host, "/l/guide", e.withDryRun("/l/guide", c.headers, c.reason))
			if searches != c.searched {
				t.Errorf("%d searches, want %d", searches, c.searched)
			}
			if c.reason != "" {
				if w.Code != http.StatusNoContent || w.Header().Get("X-Go-Web-Fallback") != c.reason {
					t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
				}
				if len(e.cache.writes) != 0 {
					t.Errorf("a dry run wrote %v", e.cache.writes)
				}
				if c.cachesOnFallback {
					if e.get(host, "/l/guide", nil); e.railsHit == nil || !strings.HasPrefix(strings.Join(e.cache.writes, " "), "go-web:storefront-catalog_") {
						t.Errorf("rails %v, cache writes %v", e.railsHit != nil, e.cache.writes)
					}
				}
				return
			}
			if w.Code != http.StatusOK {
				t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
			}
			componentProps(t, w.Body.String(), storefrontComponent)
			page := html.UnescapeString(dataPage.FindStringSubmatch(w.Body.String())[1])
			if want := c.want(e); !strings.Contains(page, want) {
				t.Errorf("want %s\nin %s", want, page)
			}
			if c.searched == 0 {
				return
			}
			var key string
			for _, k := range e.cache.writes {
				if strings.HasPrefix(k, "go-web:storefront-catalog_") {
					key = k
				}
			}
			if key == "" || e.cache.ttls[key] != 10*time.Minute {
				t.Fatalf("cache writes %v", e.cache.writes)
			}
			// The next view reads the search from the cache.
			again := html.UnescapeString(dataPage.FindStringSubmatch(e.get(host, "/l/guide", nil).Body.String())[1])
			if searches != c.searched || !strings.Contains(again, c.want(e)) {
				t.Errorf("%d searches, want %d; same catalog %v", searches, c.searched, strings.Contains(again, c.want(e)))
			}
		})
	}
}
