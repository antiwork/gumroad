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
	defaultWant := want
	var searches int
	var hits, total string
	// respond answers a case that searches more than once, by the request's body.
	var respond func(body map[string]any) (hits, total string)
	reply := func(w io.Writer, hits, total string) {
		io.WriteString(w, `{"hits":{"total":{"value":`+total+`,"relation":"eq"},"hits":`+hits+`},"aggregations":`+
			`{"tags.keyword":{"buckets":[{"key":"design","doc_count":2}]},"filetypes.keyword":{"buckets":[{"key":"pdf","doc_count":2}]}}}`)
	}
	search := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		searches++
		body, _ := io.ReadAll(r.Body)
		var got any
		if json.Unmarshal(body, &got) != nil || r.URL.Path != "/products/_search" {
			t.Errorf("search %s %s", r.URL.Path, body)
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		if respond != nil {
			h, n := respond(got.(map[string]any))
			reply(w, h, n)
			return
		}
		if !reflect.DeepEqual(got, want) {
			t.Errorf("search %s", body)
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		reply(w, hits, total)
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
		// body is the search body, when it isn't the default section's, and total its hit count
		// when it isn't 3.
		body, total string
		respond     func(body map[string]any) (hits, total string)
		// cachesOnFallback is a search kept although the page goes to Rails.
		cachesOnFallback bool
		setup            func(t *testing.T, conn *sql.DB)
		// prepare sets flags and rates; headers go with the request.
		prepare func(e *testEnv)
		headers map[string]string
		want    func(e *testEnv) string
		// check makes assertions want can't.
		check func(t *testing.T, e *testEnv, page string)
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
		{name: "a saved products section in its page layout", server: search, searched: 1, total: "2",
			hits: fmt.Sprintf(`[{"_id":"%d","_score":3.5},{"_id":"%d","_score":2.5}]`, productID, other),
			// Production's body for a page_layout section: its shown products, boosted in order.
			body: fmt.Sprintf(`{"query":{"bool":{"must":[{"terms":{"user_id":[%d]}},{"term":{"is_alive_on_profile":true}},{"terms":{"_id":[%d,%d]}}],`+
				`"should":[{"term":{"_id":{"value":%d,"boost":2}}},{"term":{"_id":{"value":%d,"boost":1}}}]}},`+
				`"aggregations":{"tags.keyword":{"terms":{"field":"tags.keyword","size":200}},"filetypes.keyword":{"terms":{"field":"filetypes.keyword","size":8}}},`+
				`"sort":[],"size":10,"from":0,"_source":false,"track_total_hits":true}`, sellerID, productID, other, productID, other),
			setup: func(t *testing.T, conn *sql.DB) {
				addOther(t, conn, map[string]any{"flags": 0})
				testdb.Insert(t, conn, "seller_profile_sections", map[string]any{"id": int64(1_792_501), "seller_id": sellerID, "header": "Picks",
					"json_data": fmt.Sprintf(`{"shown_products":[%d,%d],"default_product_sort":"page_layout","show_filters":true,"add_new_products":true}`,
						productID, other), "created_at": testNow, "updated_at": testNow})
			},
			want: func(e *testEnv) string {
				card := strings.Replace(otherCard(e), `"ratings":{"count":3,"average":4.5}`, `"ratings":null`, 1)
				card = strings.Replace(card, `"price_cents":400`, `"price_cents":300`, 1)
				return fmt.Sprintf(`"sections":[{"id":"%s","header":"Picks","type":"SellerProfileProductsSection","show_filters":true,`+
					`"default_product_sort":"page_layout","search_results":{"total":1,"tags_data":[{"key":"design","doc_count":2}],`+
					`"filetypes_data":[{"key":"pdf","doc_count":2}],"taxonomy_attributes_data":[],"products":[%s]},"exclude_ids":["%s"]}],"main_section_index":0`,
					e.ids.Encrypt(1_792_501), card, e.ids.Encrypt(productID))
			}},
		{name: "a saved section sorted newest, its header hidden", server: search, searched: 1, total: "1",
			hits: fmt.Sprintf(`[{"_id":"%d","sort":[1762430000000,1762430000000]}]`, other),
			body: fmt.Sprintf(`{"query":{"bool":{"must":[{"terms":{"user_id":[%d]}},{"term":{"is_alive_on_profile":true}},{"terms":{"_id":[%d]}}]}},`+
				`"aggregations":{"tags.keyword":{"terms":{"field":"tags.keyword","size":200}},"filetypes.keyword":{"terms":{"field":"filetypes.keyword","size":8}}},`+
				`"sort":[{"created_at":{"order":"desc"}},{"created_at":{"order":"desc"}}],"size":10,"from":0,"_source":false,"track_total_hits":true}`, sellerID, other),
			setup: func(t *testing.T, conn *sql.DB) {
				addOther(t, conn, map[string]any{"flags": 0})
				// This product isn't in the section, so the total keeps it.
				testdb.Insert(t, conn, "seller_profile_sections", map[string]any{"id": int64(1_792_502), "seller_id": sellerID, "header": "Hidden",
					"flags": 2, "json_data": fmt.Sprintf(`{"shown_products":[%d],"default_product_sort":"newest","show_filters":false,"add_new_products":true}`, other),
					"created_at": testNow, "updated_at": testNow})
			},
			want: func(e *testEnv) string {
				return fmt.Sprintf(`"sections":[{"id":"%s","header":null,"type":"SellerProfileProductsSection","show_filters":false,`+
					`"default_product_sort":"newest","search_results":{"total":1,`, e.ids.Encrypt(1_792_502))
			}},
		// The product's own listed sections replace the catalog, in Link#sections' order, without
		// omit_product; an unlisted section isn't rendered.
		{name: "the product's own sections", server: search, searched: 1, total: "1",
			hits: fmt.Sprintf(`[{"_id":"%d","sort":[1762430000000,1762430000000]}]`, other),
			body: fmt.Sprintf(`{"query":{"bool":{"must":[{"terms":{"user_id":[%d]}},{"term":{"is_alive_on_profile":true}},{"terms":{"_id":[%d]}}]}},`+
				`"aggregations":{"tags.keyword":{"terms":{"field":"tags.keyword","size":200}},"filetypes.keyword":{"terms":{"field":"filetypes.keyword","size":8}}},`+
				`"sort":[{"created_at":{"order":"desc"}},{"created_at":{"order":"desc"}}],"size":10,"from":0,"_source":false,"track_total_hits":true}`, sellerID, other),
			setup: func(t *testing.T, conn *sql.DB) {
				addOther(t, conn, map[string]any{"flags": 0})
				addProductSections(t, conn, other)
			},
			want: func(e *testEnv) string {
				card := strings.Replace(otherCard(e), `"ratings":{"count":3,"average":4.5}`, `"ratings":null`, 1)
				card = strings.Replace(card, `"price_cents":400`, `"price_cents":300`, 1)
				return fmt.Sprintf(`"sections":[%s,{"id":"%s","header":"More","type":"SellerProfileProductsSection","show_filters":false,`+
					`"default_product_sort":"newest","search_results":{"total":1,"tags_data":[{"key":"design","doc_count":2}],`+
					`"filetypes_data":[{"key":"pdf","doc_count":2}],"taxonomy_attributes_data":[],"products":[%s]}},%s],"main_section_index":1`,
					subscribeSection(e), e.ids.Encrypt(1_792_602), card, richTextSection(e))
			}},
		{name: "a listed featured product section", reason: "product section SellerProfileFeaturedProductSection", server: search,
			setup: func(t *testing.T, conn *sql.DB) {
				addSection(t, conn, 1_792_605, "SellerProfileFeaturedProductSection", "", `{}`)
				listSections(t, conn, `{"sections":[1792605]}`)
			}},
		// Sections that render nothing leave the storefront catalog in place.
		{name: "listed sections that aren't the product's", hits: bothHits, server: search, searched: 1,
			setup: func(t *testing.T, conn *sql.DB) {
				addOther(t, conn, nil)
				addSection(t, conn, 1_792_606, profileSubscribeSectionType, "", `{"button_label":"Go"}`)
				listSections(t, conn, `{"sections":[1792607]}`)
			},
			want: func(e *testEnv) string { return `"sections":[{"id":"default-products",` }},
		// Without omit_product the viewed product keeps its card and its count. A string id
		// matches as ObfuscateIds.encrypt(id.to_s) does, a repeat renders twice, and a hidden
		// header is null.
		{name: "a product section listing this product", server: search, searched: 1, total: "2",
			hits: fmt.Sprintf(`[{"_id":"%d","sort":[1762430000000,1762430000000]},{"_id":"%d","sort":[1762420000000,1762420000000]}]`, other, productID),
			body: fmt.Sprintf(`{"query":{"bool":{"must":[{"terms":{"user_id":[%d]}},{"term":{"is_alive_on_profile":true}},{"terms":{"_id":[%d,%d]}}]}},`+
				`"aggregations":{"tags.keyword":{"terms":{"field":"tags.keyword","size":200}},"filetypes.keyword":{"terms":{"field":"filetypes.keyword","size":8}}},`+
				`"sort":[{"created_at":{"order":"desc"}},{"created_at":{"order":"desc"}}],"size":10,"from":0,"_source":false,"track_total_hits":true}`,
				sellerID, other, productID),
			setup: func(t *testing.T, conn *sql.DB) {
				addOther(t, conn, map[string]any{"flags": 0})
				addSection(t, conn, 1_792_602, profileProductsSectionType, "More", fmt.Sprintf(
					`{"shown_products":[%d,%d],"default_product_sort":"newest","show_filters":false,"add_new_products":false}`, other, productID))
				addSection(t, conn, 1_792_601, profileSubscribeSectionType, "Join", `{"button_label":"Subscribe"}`)
				if _, err := conn.Exec("UPDATE seller_profile_sections SET flags = 2 WHERE id = 1792601"); err != nil {
					t.Fatal(err)
				}
				listSections(t, conn, `{"sections":["1792602",1792601,1792601]}`)
			},
			want: func(e *testEnv) string {
				return fmt.Sprintf(`"sections":[{"id":"%s","header":"More","type":"SellerProfileProductsSection","show_filters":false,`+
					`"default_product_sort":"newest","search_results":{"total":2,`, e.ids.Encrypt(1_792_602))
			},
			check: func(t *testing.T, e *testEnv, page string) {
				head := `{"id":"` + e.ids.Encrypt(1_792_601) + `","header":null,"type":"SellerProfileSubscribeSection","button_label":"Subscribe"}`
				for _, want := range []string{`"url":"https://gowebproductseller.gumroad.com/l/guide?layout=profile"`, `]}},` + head + `,` + head + `],"main_section_index":0`} {
					if !strings.Contains(page, want) {
						t.Errorf("want %s", want)
					}
				}
				if strings.Contains(page, "exclude_ids") {
					t.Error("exclude_ids on the product's own section")
				}
			}},
		// Rails builds every section of the product, so an unlisted row it raises on still counts.
		{name: "an unlisted section with no json_data", reason: "product section row", server: search,
			setup: func(t *testing.T, conn *sql.DB) {
				addSection(t, conn, 1_792_601, profileSubscribeSectionType, "Join", `{"button_label":"Subscribe"}`)
				testdb.Insert(t, conn, "seller_profile_sections", map[string]any{"id": int64(1_792_608), "seller_id": sellerID,
					"product_id": productID, "type": profileSubscribeSectionType, "json_data": nil, "created_at": testNow, "updated_at": testNow})
				listSections(t, conn, `{"sections":[1792601]}`)
			}},
		{name: "a product listing no sections, with a row Rails would raise on", reason: "product section row", server: search,
			setup: func(t *testing.T, conn *sql.DB) {
				testdb.Insert(t, conn, "seller_profile_sections", map[string]any{"id": int64(1_792_608), "seller_id": sellerID,
					"product_id": productID, "type": "SellerProfileTextSection", "json_data": `{}`, "created_at": testNow, "updated_at": testNow})
			}},
		{name: "an empty saved section", server: search, searched: 1, hits: `[]`, total: "0",
			// Rails still sends the empty id list and should clause.
			body: fmt.Sprintf(`{"query":{"bool":{"must":[{"terms":{"user_id":[%d]}},{"term":{"is_alive_on_profile":true}},{"terms":{"_id":[]}}],`+
				`"should":[]}},"aggregations":{"tags.keyword":{"terms":{"field":"tags.keyword","size":200}},"filetypes.keyword":{"terms":{"field":"filetypes.keyword","size":8}}},`+
				`"sort":[],"size":10,"from":0,"_source":false,"track_total_hits":true}`, sellerID),
			setup: func(t *testing.T, conn *sql.DB) {
				testdb.Insert(t, conn, "seller_profile_sections", map[string]any{"id": int64(1_792_504), "seller_id": sellerID,
					"json_data":  `{"shown_products":[],"default_product_sort":"page_layout","show_filters":false,"add_new_products":true}`,
					"created_at": testNow, "updated_at": testNow})
			},
			want: func(e *testEnv) string { return `"search_results":{"total":0,` }},
		// Two sections share a product: each gets its own search, total and cards.
		{name: "two saved sections sharing a product", server: search, searched: 2,
			respond: func(body map[string]any) (string, string) {
				must := body["query"].(map[string]any)["bool"].(map[string]any)["must"].([]any)
				if ids := must[2].(map[string]any)["terms"].(map[string]any)["_id"].([]any); len(ids) == 2 {
					return fmt.Sprintf(`[{"_id":"%d","_score":3.5},{"_id":"%d","_score":2.5}]`, productID, other), "2"
				}
				return fmt.Sprintf(`[{"_id":"%d","sort":[1762430000000,1762430000000]}]`, other), "1"
			},
			setup: func(t *testing.T, conn *sql.DB) {
				addOther(t, conn, map[string]any{"flags": 0})
				for i, section := range []string{
					fmt.Sprintf(`{"shown_products":[%d,%d],"default_product_sort":"page_layout","show_filters":false,"add_new_products":true}`, productID, other),
					fmt.Sprintf(`{"shown_products":[%d],"default_product_sort":"newest","show_filters":false,"add_new_products":true}`, other),
				} {
					testdb.Insert(t, conn, "seller_profile_sections", map[string]any{"id": int64(1_792_511 + i), "seller_id": sellerID,
						"header": fmt.Sprint("S", i), "json_data": section, "created_at": testNow, "updated_at": testNow})
				}
			},
			want: func(e *testEnv) string {
				card := strings.Replace(otherCard(e), `"ratings":{"count":3,"average":4.5}`, `"ratings":null`, 1)
				card = strings.Replace(card, `"price_cents":400`, `"price_cents":300`, 1)
				facets := `"tags_data":[{"key":"design","doc_count":2}],"filetypes_data":[{"key":"pdf","doc_count":2}],"taxonomy_attributes_data":[]`
				return fmt.Sprintf(`"sections":[{"id":"%s","header":"S0","type":"SellerProfileProductsSection","show_filters":false,`+
					`"default_product_sort":"page_layout","search_results":{"total":1,%s,"products":[%s]},"exclude_ids":["%s"]},`+
					`{"id":"%s","header":"S1","type":"SellerProfileProductsSection","show_filters":false,`+
					`"default_product_sort":"newest","search_results":{"total":1,%s,"products":[%s]},"exclude_ids":["%s"]}]`,
					e.ids.Encrypt(1_792_511), facets, card, e.ids.Encrypt(productID), e.ids.Encrypt(1_792_512), facets, card, e.ids.Encrypt(productID))
			}},
		{name: "a section sorted by reviews", reason: "products section review sort", server: search,
			setup: func(t *testing.T, conn *sql.DB) {
				testdb.Insert(t, conn, "seller_profile_sections", map[string]any{"id": int64(1_792_505), "seller_id": sellerID,
					"json_data":  `{"shown_products":[1],"default_product_sort":"highest_rated","show_filters":false,"add_new_products":true}`,
					"created_at": testNow, "updated_at": testNow})
			}},
		{name: "a section json_data off the schema", reason: "products section json_data", server: search,
			setup: func(t *testing.T, conn *sql.DB) {
				testdb.Insert(t, conn, "seller_profile_sections", map[string]any{"id": int64(1_792_503), "seller_id": sellerID,
					"json_data":  `{"shown_products":[],"default_product_sort":"random","show_filters":false,"add_new_products":true}`,
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
			searches, hits, want, total, respond = 0, c.hits, defaultWant, c.total, c.respond
			if total == "" {
				total = "3"
			}
			if c.body != "" {
				if err := json.Unmarshal([]byte(c.body), &want); err != nil {
					t.Fatal(err)
				}
			}
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
			if c.check != nil {
				c.check(t, e, page)
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

// addProductSections gives the product a subscribe, a products and a rich text section, listed
// in that order with main_section_index 1, and a wishlists section it doesn't list.
func addProductSections(t *testing.T, conn *sql.DB, shown int64) {
	addSection(t, conn, 1_792_601, profileSubscribeSectionType, "Join", `{"button_label":"Subscribe"}`)
	if shown != 0 {
		addSection(t, conn, 1_792_602, profileProductsSectionType, "More",
			fmt.Sprintf(`{"shown_products":[%d],"default_product_sort":"newest","show_filters":false,"add_new_products":false}`, shown))
	}
	addSection(t, conn, 1_792_603, profileRichTextSectionType, "About",
		`{"text":{"type":"doc","attrs":{"width":1.5},"content":[{"text":"Hi <b>","type":"text"}]}}`)
	addSection(t, conn, 1_792_604, "SellerProfileWishlistsSection", "Lists", `{"shown_wishlists":[1]}`)
	listSections(t, conn, `{"sections":[1792601,1792602,1792603],"main_section_index":1}`)
}

// addSection saves one of the product's own sections.
func addSection(t *testing.T, conn *sql.DB, id int64, typ, header, data string) {
	testdb.Insert(t, conn, "seller_profile_sections", map[string]any{"id": id, "seller_id": sellerID, "product_id": productID,
		"type": typ, "header": header, "json_data": data, "created_at": testNow, "updated_at": testNow})
}

// listSections sets the product's json_data.
func listSections(t *testing.T, conn *sql.DB, data string) {
	if _, err := conn.Exec("UPDATE links SET json_data = ? WHERE id = ?", data, productID); err != nil {
		t.Fatal(err)
	}
}

func subscribeSection(e *testEnv) string {
	return `{"id":"` + e.ids.Encrypt(1_792_601) + `","header":"Join","type":"SellerProfileSubscribeSection","button_label":"Subscribe"}`
}

func richTextSection(e *testEnv) string {
	return `{"id":"` + e.ids.Encrypt(1_792_603) + `","header":"About","type":"SellerProfileRichTextSection",` +
		`"text":{"type":"doc","attrs":{"width":1.5},"content":[{"text":"Hi \u003cb\u003e","type":"text"}]}}`
}

// Without the storefront, the product's own sections render on Products/Show.
func TestTheProductsOwnSections(t *testing.T) {
	e := newTestEnv(t)
	addProductSections(t, testdb.Open(t), 0)
	w := e.get(host, "/l/guide", nil)
	if w.Code != http.StatusOK || e.railsHit != nil {
		t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
	componentProps(t, w.Body.String(), productComponent)
	page := html.UnescapeString(dataPage.FindStringSubmatch(w.Body.String())[1])
	if want := `"sections":[` + subscribeSection(e) + `,` + richTextSection(e) + `],"main_section_index":1`; !strings.Contains(page, want) {
		t.Errorf("want %s\nin %s", want, page)
	}

	// A products section needs the search client.
	addSection(t, testdb.Open(t), 1_792_602, profileProductsSectionType, "More",
		`{"shown_products":[],"default_product_sort":"newest","show_filters":false,"add_new_products":false}`)
	e.render(t, nil, "products section search")
}
