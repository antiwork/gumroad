package products

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"html"
	"io"
	"maps"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/db"
	"github.com/antiwork/gumroad/go_web/internal/elastic"
	"github.com/antiwork/gumroad/go_web/internal/railscache"
	"github.com/antiwork/gumroad/go_web/internal/session/testdb"
	"github.com/antiwork/gumroad/go_web/internal/web"
)

func TestTheStorefrontCatalog(t *testing.T) {
	const other, otherPrice, category = int64(1_792_101), int64(1_792_201), int64(1_792_301)
	// Link.search_options for the default products section as production builds it, with
	// Link.filetype_options' facet on the same query.
	wantBody := fmt.Sprintf(`{"query":{"bool":{"must":[{"terms":{"user_id":[%d]}},{"term":{"is_alive_on_profile":true}}]}},`+
		`"aggregations":{"tags.keyword":{"terms":{"field":"tags.keyword","size":200}},"filetypes.keyword":{"terms":{"field":"filetypes.keyword","size":8}}},`+
		`"sort":[{"created_at":{"order":"desc"}}],"size":9,"from":0,"_source":false,"track_total_hits":true}`, sellerID)
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
	// written is the entry Rails caches for a section the fake search answers.
	written := func(id any, sort string, total int64, ids ...int64) railscache.Hash {
		s := railsCachedSection("", nil, sort, total, ids...)
		s[0].Value = id
		s[5].Value.(railscache.Hash)[2].Value = []any{railscache.Hash{{Key: "key", Value: "pdf"}, {Key: "doc_count", Value: int64(2)}}}
		return s
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
	// results is the default section's search results up to its first card, the other product's.
	results := func(e *testEnv, total int) string {
		return fmt.Sprintf(`"search_results":{"total":%d,"tags_data":[{"key":"design","doc_count":2}],"filetypes_data":[{"key":"pdf","doc_count":2}],`+
			`"taxonomy_attributes_data":[],"products":[{"id":"%s",`, total, e.ids.Encrypt(other))
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
	// legacyOther makes the other product a legacy subscription at 500 a month, whose card legacyCard is.
	legacyOther := func(t *testing.T, conn *sql.DB) {
		addOther(t, conn, map[string]any{"flags": productIsRecurringBilling, "subscription_duration": 0})
		for i, p := range []struct {
			cents      int
			recurrence string
		}{{500, "monthly"}, {4000, "yearly"}} {
			testdb.Insert(t, conn, "prices", map[string]any{"id": otherPrice + 1 + int64(i), "link_id": other, "price_cents": p.cents,
				"currency": "usd", "recurrence": p.recurrence, "created_at": testNow, "updated_at": testNow})
		}
	}
	const saleID = int64(1_792_601)
	// sale makes the other product a plain card, with otherColumns, and gives the seller an
	// auto-applied 10% sale, with saleColumns.
	sale := func(t *testing.T, conn *sql.DB, otherColumns, saleColumns map[string]any) {
		columns := map[string]any{"flags": 0}
		for k, v := range otherColumns {
			columns[k] = v
		}
		addOther(t, conn, columns)
		row := map[string]any{"code": "SALE", "amount_percentage": 10, "universal": true, "auto_apply": true}
		for k, v := range saleColumns {
			row[k] = v
		}
		insertOfferCode(t, conn, saleID, row)
	}
	// rentable makes the other product a plain card of purchaseType, which also rents at 150.
	rentable := func(t *testing.T, conn *sql.DB, purchaseType int) {
		addOther(t, conn, map[string]any{"flags": 0, "purchase_type": purchaseType})
		testdb.Insert(t, conn, "prices", map[string]any{"id": otherPrice + 1, "link_id": other, "price_cents": 150, "currency": "usd",
			"flags": priceIsRental, "created_at": testNow, "updated_at": testNow})
	}
	// saleCard is the other product's card at price, ending in tail.
	saleCard := func(e *testEnv, price int, tail string) string {
		card := strings.Replace(otherCard(e), `"ratings":{"count":3,"average":4.5}`, `"ratings":null`, 1)
		card = strings.Replace(card, `"price_cents":400`, fmt.Sprintf(`"price_cents":%d`, price), 1)
		return strings.Replace(card, `"recurrence":null}`, `"recurrence":null`+tail+`}`, 1)
	}
	const onSale = `,"original_price_cents":300,"sale_label":"Sale"`
	// tieredSale makes the sale tiered by ownership, storing its first tier's 10% as the dashboard
	// does, and has the buyer buy this product months ago.
	tieredSale := func(t *testing.T, conn *sql.DB, months int) {
		sale(t, conn, nil, map[string]any{
			"ownership_duration_tiers": `[{"months":0,"amount_percentage":10},{"months":6,"amount_percentage":15},{"months":12,"amount_percentage":25}]`})
		addBuyer(t, conn, nil)
		addPurchase(t, conn, 1_792_661, map[string]any{"purchaser_id": buyerID, "created_at": testNow.AddDate(0, -months, 0)})
	}
	// tierDiscount is this product's discount_code at the buyer's tier.
	tierDiscount := func(percents int) string {
		return fmt.Sprintf(`"discount_code":{"valid":true,"code":"SALE","discount":{"type":"percent","percents":%d,"product_ids":null,`, percents)
	}
	// scopedSale is a sale, left off this product, scoped to the other product's option at index
	// scoped among options with the price differences diffs.
	scopedSale := func(t *testing.T, conn *sql.DB, scoped int, diffs ...any) {
		sale(t, conn, nil, nil)
		insertExcludedProduct(t, conn, 1_792_611, saleID, productID)
		testdb.Insert(t, conn, "variant_categories", map[string]any{"id": category, "link_id": other, "title": "Size"})
		for i, diff := range diffs {
			testdb.Insert(t, conn, "base_variants", map[string]any{"id": int64(1_792_631 + i), "type": "Variant", "variant_category_id": category,
				"name": "V", "price_difference_cents": diff, "created_at": testNow, "updated_at": testNow})
		}
		testdb.Insert(t, conn, "offer_codes_variants", map[string]any{"id": int64(1_792_621), "offer_code_id": saleID,
			"variant_id": int64(1_792_631 + scoped)})
	}
	legacyCard := func(e *testEnv) string {
		card := strings.Replace(otherCard(e), `"ratings":{"count":3,"average":4.5}`, `"ratings":null`, 1)
		card = strings.Replace(card, `"recurrence":null`, `"recurrence":"monthly"`, 1)
		return strings.Replace(card, `"price_cents":400`, `"price_cents":500`, 1)
	}

	// ownResults is the product's own products section's results, finding the other product.
	ownResults := func(e *testEnv) string {
		return `"search_results":{"total":1,"tags_data":[{"key":"design","doc_count":2}],"filetypes_data":[{"key":"pdf","doc_count":2}],` +
			`"taxonomy_attributes_data":[],"products":[{"id":"` + e.ids.Encrypt(other) + `","permalink":"gowebp2"`
	}
	ownHits := fmt.Sprintf(`[{"_id":"%d","sort":[1762430000000,1762430000000]}]`, other)
	ownBody := fmt.Sprintf(`{"query":{"bool":{"must":[{"terms":{"user_id":[%d]}},{"term":{"is_alive_on_profile":true}},{"terms":{"_id":[%d]}}]}},`+
		`"aggregations":{"tags.keyword":{"terms":{"field":"tags.keyword","size":200}},"filetypes.keyword":{"terms":{"field":"filetypes.keyword","size":8}}},`+
		`"sort":[{"created_at":{"order":"desc"}},{"created_at":{"order":"desc"}}],"size":9,"from":0,"_source":false,"track_total_hits":true}`, sellerID, other)
	// unlisted adds a products section the product doesn't list, finding the other product.
	unlisted := func(t *testing.T, conn *sql.DB) {
		addOther(t, conn, map[string]any{"flags": 0})
		addProductSections(t, conn, other)
		addSection(t, conn, 1_792_609, profileProductsSectionType, "Hidden",
			fmt.Sprintf(`{"shown_products":[%d],"default_product_sort":"newest","show_filters":false,"add_new_products":false}`, other))
	}
	unlistedEntry := func(e *testEnv, found int64) railscache.Hash {
		s := railsCachedSection(e.ids.Encrypt(1_792_609), "Hidden", "newest", 1, found)
		s[5].Value.(railscache.Hash)[2].Value = []any{railscache.Hash{{Key: "key", Value: "pdf"}, {Key: "doc_count", Value: int64(2)}}}
		return s
	}

	// cardJobs is the queue a case's prepare gives the page.
	var cardJobs interface {
		List(key string) ([]string, error)
	}
	for _, c := range []struct {
		name, reason, hits string
		server             *httptest.Server
		searched           int
		// body is the search body, when it isn't the default section's, and total its hit count
		// when it isn't 3.
		body, total string
		respond     func(body map[string]any) (hits, total string)
		setup       func(t *testing.T, conn *sql.DB)
		// prepare sets flags and rates; headers and query go with the request, and signedIn
		// signs the buyer in in place of headers.
		prepare  func(e *testEnv)
		headers  map[string]string
		signedIn bool
		query    string
		// searchedAgain is the searches after a second view, when it differs from searched.
		searchedAgain int
		want          func(e *testEnv) string
		// check makes assertions want can't.
		check func(t *testing.T, e *testEnv, page string)
	}{
		// A visitor search param searches afresh after the cached fetch, on every view, and goes into
		// the cards' URLs and the byline's.
		{name: "a recommendation", hits: bothHits, server: search, searched: 2, searchedAgain: 3, query: "?recommended_by=more_like_this",
			setup: func(t *testing.T, conn *sql.DB) { addOther(t, conn, nil) },
			want: func(e *testEnv) string {
				return `"url":"https://` + host + `/l/gowebp2?layout=profile\u0026recommended_by=more_like_this"`
			},
			check: func(t *testing.T, e *testEnv, page string) {
				if want := `"profile_url":"https://` + host + `/?recommended_by=more_like_this"`; !strings.Contains(page, want) {
					t.Errorf("want %s", want)
				}
			}},
		// A visitor's query narrows section_props' fresh search, never the cached one.
		{name: "a visitor query", server: search, searched: 2, searchedAgain: 3, query: "?query=pen+set",
			setup: func(t *testing.T, conn *sql.DB) { addOther(t, conn, nil) },
			respond: func(body map[string]any) (string, string) {
				must := body["query"].(map[string]any)["bool"].(map[string]any)["must"].([]any)
				// The first is the cached fetch, whose entry is keyed without the query.
				if searches == 1 && len(must) != 2 {
					t.Errorf("the cached search carried the query: %v", must)
				}
				match := map[string]any{"simple_query_string": map[string]any{"query": "pen set",
					"fields": []any{"name", "creator_name", "description", "tags"}, "default_operator": "and"}}
				switch {
				case len(must) == 2:
					return bothHits, "3"
				case len(must) == 3 && reflect.DeepEqual(must[0], match):
					return fmt.Sprintf(`[{"_id":"%d","sort":[1762430000000]}]`, other), "1"
				}
				return `[]`, "0"
			},
			// omit_product_in_search_total? drops the viewed product from the default section's total
			// whether or not it matches the query.
			want: func(e *testEnv) string { return results(e, 0) }},
		// A blank one still searches afresh, with no clause.
		{name: "a blank visitor query", hits: bothHits, server: search, searched: 2, searchedAgain: 3, query: "?query=+",
			setup: func(t *testing.T, conn *sql.DB) { addOther(t, conn, nil) },
			want:  func(e *testEnv) string { return results(e, 2) }},
		// search_options' from is (from.to_i - 1).clamp(0, ...), so a referral tag reads as the first page.
		{name: "a referral tag in from", hits: bothHits, server: search, searched: 2, searchedAgain: 3, query: "?from=threads",
			setup: func(t *testing.T, conn *sql.DB) { addOther(t, conn, nil) },
			want:  func(e *testEnv) string { return results(e, 2) }},
		{name: "a later page", server: search, searched: 2, searchedAgain: 3, query: "?from=10",
			setup: func(t *testing.T, conn *sql.DB) { addOther(t, conn, nil) },
			respond: func(body map[string]any) (string, string) {
				if body["from"] == float64(9) {
					return fmt.Sprintf(`[{"_id":"%d","sort":[1762430000000]}]`, other), "10"
				}
				return bothHits, "3"
			},
			want: func(e *testEnv) string { return results(e, 9) }},
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
			want: func(e *testEnv) string { return section(e, 2, otherCard(e)) },
			check: func(t *testing.T, e *testEnv, _ string) {
				// Rails reads this back: the virtual section's entry is a lone Hash, its id a UTF-8 literal.
				if got := e.cache.values[railsSectionsKey(e, true)]; !reflect.DeepEqual(got, written(defaultProductsSectionID, pageLayoutSort, 3, other, productID)) {
					t.Errorf("entry %#v", got)
				}
			}},
		// preloaded_options' floor takes the alive SKUs, the default one too, with the variants; a SKU
		// without a difference is compacted out.
		{name: "SKUs below the variants", hits: bothHits, server: search, searched: 1,
			setup: func(t *testing.T, conn *sql.DB) {
				addOther(t, conn, nil)
				testdb.Insert(t, conn, "variant_categories", map[string]any{"id": category, "link_id": other, "title": "Size"})
				testdb.Insert(t, conn, "base_variants", map[string]any{"id": category + 1, "type": "Variant", "variant_category_id": category,
					"name": "V", "price_difference_cents": 100, "sales_count_for_inventory_cache": 0, "created_at": testNow, "updated_at": testNow})
				for i, sku := range []map[string]any{{"price_difference_cents": 50, "flags": baseVariantIsDefaultSku},
					{"price_difference_cents": 10, "deleted_at": testNow}, {"price_difference_cents": nil}} {
					row := map[string]any{"id": int64(1_792_311 + i), "type": "Sku", "link_id": other, "name": "S",
						"sales_count_for_inventory_cache": 0, "created_at": testNow, "updated_at": testNow}
					maps.Copy(row, sku)
					testdb.Insert(t, conn, "base_variants", row)
				}
				testdb.Insert(t, conn, "product_review_stats", map[string]any{"id": int64(1_792_401), "link_id": other, "reviews_count": 3,
					"average_rating": 4.5, "created_at": testNow, "updated_at": testNow})
			},
			want: func(e *testEnv) string {
				return section(e, 2, strings.Replace(otherCard(e), `"price_cents":400`, `"price_cents":350`, 1))
			}},
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
		// url_from_file queues the missing variant and serves the original.
		{name: "a card's image cover without its retina variant", server: search, searched: 1,
			hits: fmt.Sprintf(`[{"_id":"%d","sort":[1762430000000]}]`, other),
			setup: func(t *testing.T, conn *sql.DB) {
				addOther(t, conn, map[string]any{"flags": 0})
				testdb.Insert(t, conn, "asset_previews", map[string]any{"id": int64(1_792_602), "link_id": other, "guid": "g",
					"position": 0, "created_at": testNow, "updated_at": testNow})
				testdb.Insert(t, conn, "active_storage_blobs", map[string]any{"id": int64(1_792_702), "key": "covers/1", "filename": "a.jpg",
					"content_type": "image/jpeg", "metadata": `{"identified":true,"width":2000,"height":1000,"analyzed":true}`,
					"service_name": "amazon_public", "byte_size": 1, "created_at": testNow})
				testdb.Insert(t, conn, "active_storage_attachments", map[string]any{"id": int64(1_792_802), "name": "file",
					"record_type": "AssetPreview", "record_id": int64(1_792_602), "blob_id": int64(1_792_702), "created_at": testNow})
			},
			prepare: func(e *testEnv) { cardJobs = sidekiqJobs(t, e) },
			want: func(e *testEnv) string {
				card := strings.Replace(otherCard(e), `"ratings":{"count":3,"average":4.5}`, `"ratings":null`, 1)
				card = strings.Replace(card, `"thumbnail_url":null`, `"thumbnail_url":"https://public-files.gumroad.com/covers/1"`, 1)
				return section(e, 2, strings.Replace(card, `"price_cents":400`, `"price_cents":300`, 1))
			},
			check: func(t *testing.T, e *testEnv, _ string) {
				queued, _ := cardJobs.List("queue:low")
				if len(queued) != 1 || !strings.Contains(queued[0], `"args":[1792602],"class":"ProcessAssetPreviewRetinaWorker"`) {
					t.Errorf("queue:low %v", queued)
				}
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
		// A second file of the same thumbnail, with a lower attachment id: has_one keeps the lower blob_id.
		{name: "a card's thumbnail with two files", server: search, searched: 1,
			hits: fmt.Sprintf(`[{"_id":"%d","sort":[1762430000000]}]`, other),
			setup: func(t *testing.T, conn *sql.DB) {
				addOther(t, conn, map[string]any{"flags": 0})
				testdb.Insert(t, conn, "thumbnails", map[string]any{"id": int64(1_792_951), "product_id": other, "guid": "t",
					"created_at": testNow, "updated_at": testNow})
				for i, key := range []string{"thumbnails/original", "thumbnails/600", "thumbnails/other"} {
					testdb.Insert(t, conn, "active_storage_blobs", map[string]any{"id": int64(1_792_961 + i), "key": key, "filename": "t.png",
						"content_type": "image/png", "service_name": "amazon_public", "byte_size": 1, "created_at": testNow})
				}
				testdb.Insert(t, conn, "active_storage_attachments", map[string]any{"id": int64(1_792_971), "name": "file",
					"record_type": "Thumbnail", "record_id": int64(1_792_951), "blob_id": int64(1_792_961), "created_at": testNow})
				testdb.Insert(t, conn, "active_storage_attachments", map[string]any{"id": int64(1_792_970), "name": "file",
					"record_type": "Thumbnail", "record_id": int64(1_792_951), "blob_id": int64(1_792_963), "created_at": testNow})
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
		// file.variant raises for a type ActiveStorage can't resize, and Thumbnail#url rescues
		// with the upload.
		{name: "a card's thumbnail ActiveStorage can't resize", server: search, searched: 1,
			hits: fmt.Sprintf(`[{"_id":"%d","sort":[1762430000000]}]`, other),
			setup: func(t *testing.T, conn *sql.DB) {
				addOther(t, conn, map[string]any{"flags": 0})
				testdb.Insert(t, conn, "thumbnails", map[string]any{"id": int64(1_792_951), "product_id": other, "guid": "t",
					"created_at": testNow, "updated_at": testNow})
				testdb.Insert(t, conn, "active_storage_blobs", map[string]any{"id": int64(1_792_961), "key": "thumbnails/vector", "filename": "t.svg",
					"content_type": "image/svg+xml", "service_name": "amazon_public", "byte_size": 1, "created_at": testNow})
				testdb.Insert(t, conn, "active_storage_attachments", map[string]any{"id": int64(1_792_971), "name": "file",
					"record_type": "Thumbnail", "record_id": int64(1_792_951), "blob_id": int64(1_792_961), "created_at": testNow})
			},
			want: func(e *testEnv) string {
				card := strings.Replace(otherCard(e), `"ratings":{"count":3,"average":4.5}`, `"ratings":null`, 1)
				card = strings.Replace(card, `"thumbnail_url":null`, `"thumbnail_url":"https://public-files.gumroad.com/thumbnails/vector"`, 1)
				return section(e, 2, strings.Replace(card, `"price_cents":400`, `"price_cents":300`, 1))
			}},
		// has_one's preload keeps the first row its statement returns, here the lower id.
		{name: "a card with two thumbnails", server: search, searched: 1,
			hits: fmt.Sprintf(`[{"_id":"%d","sort":[1762430000000]}]`, other),
			setup: func(t *testing.T, conn *sql.DB) {
				addOther(t, conn, map[string]any{"flags": 0})
				for i, url := range []string{"https://images.unsplash.com/x", "https://images.unsplash.com/y"} {
					testdb.Insert(t, conn, "thumbnails", map[string]any{"id": int64(1_792_952 + i), "product_id": other, "unsplash_url": url,
						"created_at": testNow, "updated_at": testNow})
				}
			},
			want: func(e *testEnv) string {
				card := strings.Replace(otherCard(e), `"ratings":{"count":3,"average":4.5}`, `"ratings":null`, 1)
				card = strings.Replace(card, `"thumbnail_url":null`, `"thumbnail_url":"https://images.unsplash.com/x"`, 1)
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
			hits:  fmt.Sprintf(`[{"_id":"%d","sort":[1762430000000]}]`, other),
			setup: legacyOther,
			want:  func(e *testEnv) string { return section(e, 2, legacyCard(e)) }},
		{name: "a tiered membership without a duration", reason: "catalog subscription duration", hits: bothHits, server: search, searched: 1,
			setup: func(t *testing.T, conn *sql.DB) {
				tieredOther(t, conn)
				conn.Exec("UPDATE links SET subscription_duration = NULL WHERE id = ?", other)
			}},
		{name: "a membership card with a local price", hits: bothHits, server: search, searched: 1, headers: eurCookie,
			setup:   legacyOther,
			prepare: func(e *testEnv) { e.localEUR("0.92345") },
			want: func(e *testEnv) string {
				return section(e, 2, strings.Replace(legacyCard(e), `"buyer_currency_shown":"usd","product_currency":"usd",`+
					`"buyer_local_price_cents":null,"rate":null,"display_mode":"default"}`, `"buyer_currency_shown":"eur","product_currency":"usd",`+
					`"buyer_local_price_cents":462,"rate":0.92345,"display_mode":"buyer_local"},"buyer_currency":"eur","buyer_local_currency_rate":0.92345,`+
					`"buyer_local_currency_subunit_to_unit":100,"buyer_local_price_cents":462`, 1))
			}},
		// The page's own one-time product shows reais, which the India mandate can't take for the
		// membership card.
		{name: "a membership card in a currency the mandate doesn't take", hits: bothHits, server: search, searched: 1,
			headers: map[string]string{"Cookie": "gumroad_buyer_currency=BRL"},
			setup: func(t *testing.T, conn *sql.DB) {
				legacyOther(t, conn)
				insertPlatformAccount(t, conn, "usd", `{}`)
			},
			prepare: func(e *testEnv) {
				e.localEUR("0.92345")
				e.redis.Set("currencies:BRL", "5.4321")
				for _, flag := range []string{"buyer_currency_charging", "buyer_currency_subscriptions", "india_card_mandate_reliability"} {
					e.redis.HSet(flag, "boolean", "true")
				}
			},
			want: func(e *testEnv) string { return section(e, 2, legacyCard(e)) }},
		// Tied hits keep the order the search returns, as Rails caches and renders them.
		{name: "tied hits", server: search, searched: 1,
			hits:  fmt.Sprintf(`[{"_id":"%d","sort":[1762430000000]},{"_id":"%d","sort":[1762430000000]}]`, other, productID),
			setup: func(t *testing.T, conn *sql.DB) { addOther(t, conn, nil) },
			check: func(t *testing.T, e *testEnv, _ string) {
				if got := e.cache.values[railsSectionsKey(e, true)]; !reflect.DeepEqual(got, written(defaultProductsSectionID, pageLayoutSort, 3, other, productID)) {
					t.Errorf("entry %#v", got)
				}
			},
			want: func(e *testEnv) string { return results(e, 2) }},
		{name: "a sold-out product hidden", hits: bothHits, server: search, searched: 1,
			setup: func(t *testing.T, conn *sql.DB) {
				addOther(t, conn, map[string]any{"flags": productHideSoldOutVariants, "max_purchase_count": 0})
			},
			want: func(e *testEnv) string { return section(e, 1, "") }},
		{name: "a sold-out tiered membership hidden", hits: bothHits, server: search, searched: 1,
			setup: func(t *testing.T, conn *sql.DB) {
				tieredOther(t, conn)
				conn.Exec("UPDATE links SET flags = flags | ?, max_purchase_count = 0 WHERE id = ?", productHideSoldOutVariants, other)
			},
			want: func(e *testEnv) string { return section(e, 1, "") }},
		{name: "a bundle of a sold-out product hidden", hits: bothHits, server: search, searched: 1,
			setup: func(t *testing.T, conn *sql.DB) {
				addOther(t, conn, map[string]any{"flags": productHideSoldOutVariants | productIsBundle, "native_type": "bundle"})
				testdb.Insert(t, conn, "links", map[string]any{"id": other + 50, "user_id": sellerID, "name": "Part", "unique_permalink": "gowebpart",
					"price_cents": 100, "max_purchase_count": 0, "created_at": testNow, "updated_at": testNow})
				testdb.Insert(t, conn, "bundle_products", map[string]any{"id": int64(1_792_591), "bundle_id": other, "product_id": other + 50,
					"quantity": 1, "position": 0, "created_at": testNow, "updated_at": testNow})
			},
			want: func(e *testEnv) string { return section(e, 1, "") }},
		// No alive bundle product leaves the minimum nil, so nothing limits it.
		{name: "an empty bundle shown", hits: bothHits, server: search, searched: 1,
			setup: func(t *testing.T, conn *sql.DB) {
				addOther(t, conn, map[string]any{"flags": productHideSoldOutVariants | productIsBundle, "native_type": "bundle"})
			},
			want: func(e *testEnv) string {
				return `{"id":"` + e.ids.Encrypt(other) + `","permalink":"gowebp2","name":"Other",`
			}},
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
				`"sort":[],"size":9,"from":0,"_source":false,"track_total_hits":true}`, sellerID, productID, other, productID, other),
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
				`"sort":[{"created_at":{"order":"desc"}},{"created_at":{"order":"desc"}}],"size":9,"from":0,"_source":false,"track_total_hits":true}`, sellerID, other),
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
				`"sort":[{"created_at":{"order":"desc"}},{"created_at":{"order":"desc"}}],"size":9,"from":0,"_source":false,"track_total_hits":true}`, sellerID, other),
			setup: func(t *testing.T, conn *sql.DB) {
				addOther(t, conn, map[string]any{"flags": 0})
				addProductSections(t, conn, other)
			},
			// The entry holds every section, listed or not, as cached_sections builds it.
			check: func(t *testing.T, e *testEnv, page string) {
				entry := e.cache.values[productSectionsKey(e, 4)]
				if want := productSectionsEntry(e, other); !reflect.DeepEqual(entry, want) {
					t.Errorf("entry %#v\nwant %#v", entry, want)
				}
				if _, err := railscache.Dump(entry); err != nil {
					t.Error(err)
				}
			},
			want: func(e *testEnv) string {
				card := strings.Replace(otherCard(e), `"ratings":{"count":3,"average":4.5}`, `"ratings":null`, 1)
				card = strings.Replace(card, `"price_cents":400`, `"price_cents":300`, 1)
				return fmt.Sprintf(`"sections":[%s,{"id":"%s","header":"More","type":"SellerProfileProductsSection","show_filters":false,`+
					`"default_product_sort":"newest","search_results":{"total":1,"tags_data":[{"key":"design","doc_count":2}],`+
					`"filetypes_data":[{"key":"pdf","doc_count":2}],"taxonomy_attributes_data":[],"products":[%s]}},%s],"main_section_index":1`,
					subscribeSection(e), e.ids.Encrypt(1_792_602), card, richTextSection(e))
			}},
		// Rails' entry renders without a search.
		{name: "the product's own sections from Rails' cache", server: search,
			setup: func(t *testing.T, conn *sql.DB) {
				addOther(t, conn, map[string]any{"flags": 0})
				addProductSections(t, conn, other)
			},
			prepare: func(e *testEnv) { e.cache.values[productSectionsKey(e, 4)] = productSectionsEntry(e, other) },
			want:    ownResults},
		// An entry that isn't the product's rows is one Rails would render differently.
		{name: "Rails' entry for fewer sections", reason: "cached sections", server: search,
			setup: func(t *testing.T, conn *sql.DB) {
				addOther(t, conn, map[string]any{"flags": 0})
				addProductSections(t, conn, other)
			},
			prepare: func(e *testEnv) { e.cache.values[productSectionsKey(e, 4)] = productSectionsEntry(e, other)[:3] }},
		// cached_sections searches and caches an unlisted products section too; the next view reads it.
		{name: "an unlisted products section", server: search, searched: 2, total: "1", hits: ownHits, body: ownBody,
			setup: unlisted,
			check: func(t *testing.T, e *testEnv, page string) {
				entry, _ := e.cache.values[productSectionsKey(e, 5)].([]any)
				if want := append(productSectionsEntry(e, other), unlistedEntry(e, other)); !reflect.DeepEqual(entry, want) {
					t.Errorf("entry %#v\nwant %#v", entry, want)
				}
			},
			want: ownResults},
		// section_props finds an unlisted section's products too, and raises on one that's gone.
		{name: "an unlisted section's product that's gone", reason: "catalog product missing", server: search, setup: unlisted,
			prepare: func(e *testEnv) {
				e.cache.values[productSectionsKey(e, 5)] = append(productSectionsEntry(e, other), unlistedEntry(e, 1_792_999))
			}},
		// Rails' entry for a product's own sections is shared, a review sort's too: the next view
		// reads it.
		{name: "the product's own review-sorted section", server: search, searched: 1, total: "1",
			hits: fmt.Sprintf(`[{"_id":"%d","sort":[4.5,3,1762430000000]}]`, other),
			body: fmt.Sprintf(`{"query":{"bool":{"must":[{"terms":{"user_id":[%d]}},{"term":{"is_alive_on_profile":true}},{"terms":{"_id":[%d]}}]}},`+
				`"aggregations":{"tags.keyword":{"terms":{"field":"tags.keyword","size":200}},"filetypes.keyword":{"terms":{"field":"filetypes.keyword","size":8}}},`+
				`"sort":[{"average_rating":{"order":"desc"}},{"reviews_count":{"order":"desc"}},{"created_at":{"order":"desc"}}],`+
				`"size":9,"from":0,"_source":false,"track_total_hits":true}`, sellerID, other),
			setup: func(t *testing.T, conn *sql.DB) {
				addOther(t, conn, map[string]any{"flags": 0})
				addSection(t, conn, 1_792_602, profileProductsSectionType, "More",
					fmt.Sprintf(`{"shown_products":[%d],"default_product_sort":"highest_rated","show_filters":false,"add_new_products":false}`, other))
				listSections(t, conn, `{"sections":[1792602]}`)
			},
			want: func(e *testEnv) string {
				return `"products":[{"id":"` + e.ids.Encrypt(other) + `","permalink":"gowebp2"`
			}},
		// A visitor search param searches it afresh after the cached fetch.
		{name: "the product's own review-sorted section with a recommendation", server: search, searched: 2, searchedAgain: 3,
			total: "1", query: "?recommended_by=wishlist",
			hits: fmt.Sprintf(`[{"_id":"%d","sort":[4.5,3,1762430000000]}]`, other),
			body: fmt.Sprintf(`{"query":{"bool":{"must":[{"terms":{"user_id":[%d]}},{"term":{"is_alive_on_profile":true}},{"terms":{"_id":[%d]}}]}},`+
				`"aggregations":{"tags.keyword":{"terms":{"field":"tags.keyword","size":200}},"filetypes.keyword":{"terms":{"field":"filetypes.keyword","size":8}}},`+
				`"sort":[{"average_rating":{"order":"desc"}},{"reviews_count":{"order":"desc"}},{"created_at":{"order":"desc"}}],`+
				`"size":9,"from":0,"_source":false,"track_total_hits":true}`, sellerID, other),
			setup: func(t *testing.T, conn *sql.DB) {
				addOther(t, conn, map[string]any{"flags": 0})
				addSection(t, conn, 1_792_602, profileProductsSectionType, "More",
					fmt.Sprintf(`{"shown_products":[%d],"default_product_sort":"highest_rated","show_filters":false,"add_new_products":false}`, other))
				listSections(t, conn, `{"sections":[1792602]}`)
			},
			want: func(e *testEnv) string {
				return `"url":"https://` + host + `/l/gowebp2?layout=profile\u0026recommended_by=wishlist"`
			}},
		// A featured section naming no product has no props; listed, it replaces the catalog.
		{name: "a listed featured section without a product", server: search,
			setup: func(t *testing.T, conn *sql.DB) {
				addSection(t, conn, 1_792_605, profileFeaturedSectionType, "", `{}`)
				listSections(t, conn, `{"sections":[1792605]}`)
			},
			want: func(e *testEnv) string {
				return `"sections":[{"id":"` + e.ids.Encrypt(1_792_605) + `","header":"","type":"SellerProfileFeaturedProductSection","props":null}],"main_section_index":0`
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
				`"sort":[{"created_at":{"order":"desc"}},{"created_at":{"order":"desc"}}],"size":9,"from":0,"_source":false,"track_total_hits":true}`,
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
				`"sort":[],"size":9,"from":0,"_source":false,"track_total_hits":true}`, sellerID),
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
		// Rails' cached_sections entry is the order Rails renders, so go_web serves it without a
		// search, a review-sorted section included.
		{name: "a review-sorted section from Rails' cache", server: search,
			setup: func(t *testing.T, conn *sql.DB) {
				addOther(t, conn, map[string]any{"flags": 0})
				testdb.Insert(t, conn, "seller_profile_sections", map[string]any{"id": int64(1_792_509), "seller_id": sellerID, "header": "Top",
					"json_data":  fmt.Sprintf(`{"shown_products":[%d],"default_product_sort":"highest_rated","show_filters":false,"add_new_products":true}`, other),
					"created_at": testNow, "updated_at": testNow})
			},
			prepare: func(e *testEnv) {
				e.cache.values[railsSectionsKey(e, false)] = []any{railsCachedSection(e.ids.Encrypt(1_792_509), "Top", "highest_rated", 1, other)}
			},
			want: func(e *testEnv) string {
				card := strings.Replace(otherCard(e), `"ratings":{"count":3,"average":4.5}`, `"ratings":null`, 1)
				card = strings.Replace(card, `"price_cents":400`, `"price_cents":300`, 1)
				return fmt.Sprintf(`"sections":[{"id":"%s","header":"Top","type":"SellerProfileProductsSection","show_filters":false,`+
					`"default_product_sort":"highest_rated","search_results":{"total":1,"tags_data":[{"key":"design","doc_count":2}],`+
					`"filetypes_data":[],"taxonomy_attributes_data":[],"products":[%s]},"exclude_ids":["%s"]}],"main_section_index":0`,
					e.ids.Encrypt(1_792_509), card, e.ids.Encrypt(productID))
			}},
		// cached_default_products_section's entry wins over a search too, with this product omitted.
		{name: "the default section from Rails' cache", server: search,
			setup: func(t *testing.T, conn *sql.DB) { addOther(t, conn, nil) },
			prepare: func(e *testEnv) {
				e.cache.values[railsSectionsKey(e, true)] = railsCachedSection(defaultProductsSectionID, nil, pageLayoutSort, 2, other, productID)
			},
			want: func(e *testEnv) string {
				return `"search_results":{"total":1,"tags_data":[{"key":"design","doc_count":2}],"filetypes_data":[],` +
					`"taxonomy_attributes_data":[],"products":[{"id":"` + e.ids.Encrypt(other) + `","permalink":"gowebp2"`
			}},
		// Rails would render its entry's sections, in its order; a different list goes to Rails.
		{name: "Rails' cached sections in another order", reason: "cached sections", server: search,
			setup: func(t *testing.T, conn *sql.DB) {
				for _, id := range []int64{1_792_509, 1_792_510} {
					testdb.Insert(t, conn, "seller_profile_sections", map[string]any{"id": id, "seller_id": sellerID, "header": "Top",
						"json_data":  `{"shown_products":[],"default_product_sort":"newest","show_filters":false,"add_new_products":true}`,
						"created_at": testNow, "updated_at": testNow})
				}
			},
			prepare: func(e *testEnv) {
				e.cache.values[railsSectionsKey(e, false)] = []any{railsCachedSection(e.ids.Encrypt(1_792_510), "Top", "newest", 0),
					railsCachedSection(e.ids.Encrypt(1_792_509), "Top", "newest", 0)}
			}},
		// Without Rails' entry, the search runs and its entry is written for both to read.
		{name: "a section sorted by reviews", server: search, searched: 1, hits: `[]`, total: "0",
			body: fmt.Sprintf(`{"query":{"bool":{"must":[{"terms":{"user_id":[%d]}},{"term":{"is_alive_on_profile":true}},{"terms":{"_id":[1]}}]}},`+
				`"aggregations":{"tags.keyword":{"terms":{"field":"tags.keyword","size":200}},"filetypes.keyword":{"terms":{"field":"filetypes.keyword","size":8}}},`+
				`"sort":[{"average_rating":{"order":"desc"}},{"reviews_count":{"order":"desc"}},{"created_at":{"order":"desc"}}],`+
				`"size":9,"from":0,"_source":false,"track_total_hits":true}`, sellerID),
			setup: func(t *testing.T, conn *sql.DB) {
				testdb.Insert(t, conn, "seller_profile_sections", map[string]any{"id": int64(1_792_505), "seller_id": sellerID,
					"json_data":  `{"shown_products":[1],"default_product_sort":"highest_rated","show_filters":false,"add_new_products":true}`,
					"created_at": testNow, "updated_at": testNow})
			},
			want: func(e *testEnv) string {
				return fmt.Sprintf(`"sections":[{"id":"%s","header":null,"type":"SellerProfileProductsSection","show_filters":false,`+
					`"default_product_sort":"highest_rated","search_results":{"total":0,`, e.ids.Encrypt(1_792_505))
			},
			check: func(t *testing.T, e *testEnv, _ string) {
				want := []any{written(railscache.ASCII(e.ids.Encrypt(1_792_505)), "highest_rated", 0)}
				if got := e.cache.values[railsSectionsKey(e, false)]; !reflect.DeepEqual(got, want) {
					t.Errorf("entry %#v", got)
				}
			}},
		{name: "a section json_data off the schema", reason: "products section json_data", server: search,
			setup: func(t *testing.T, conn *sql.DB) {
				testdb.Insert(t, conn, "seller_profile_sections", map[string]any{"id": int64(1_792_503), "seller_id": sellerID,
					"json_data":  `{"shown_products":[],"default_product_sort":"random","show_filters":false,"add_new_products":true}`,
					"created_at": testNow, "updated_at": testNow})
			}},
		{name: "a card this port leaves to Rails", reason: "catalog purchase type", hits: bothHits, server: search, searched: 1,
			setup: func(t *testing.T, conn *sql.DB) {
				addOther(t, conn, map[string]any{"purchase_type": 5})
			}},
		{name: "the seller's sale on a card", hits: bothHits, server: search, searched: 1,
			setup: func(t *testing.T, conn *sql.DB) { sale(t, conn, nil, nil) },
			want:  func(e *testEnv) string { return section(e, 2, saleCard(e, 270, onSale)) }},
		{name: "the sale's own label", hits: bothHits, server: search, searched: 1,
			setup: func(t *testing.T, conn *sql.DB) { sale(t, conn, nil, map[string]any{"sale_label": "Black Friday"}) },
			want: func(e *testEnv) string {
				return section(e, 2, saleCard(e, 270, `,"original_price_cents":300,"sale_label":"Black Friday"`))
			}},
		// The buyer's tier is this product's; discounted_price_cents prices a card through the
		// sale's stored percentage, whatever the buyer has owned.
		{name: "a tiered sale for a buyer of 7 months", hits: bothHits, server: search, searched: 1, signedIn: true,
			setup: func(t *testing.T, conn *sql.DB) { tieredSale(t, conn, 7) },
			want:  func(e *testEnv) string { return section(e, 2, saleCard(e, 270, onSale)) },
			check: func(t *testing.T, e *testEnv, page string) {
				if want := tierDiscount(15); !strings.Contains(page, want) {
					t.Errorf("want %s", want)
				}
			}},
		{name: "a tiered sale for a buyer of 13 months", hits: bothHits, server: search, searched: 1, signedIn: true,
			setup: func(t *testing.T, conn *sql.DB) { tieredSale(t, conn, 13) },
			want:  func(e *testEnv) string { return section(e, 2, saleCard(e, 270, onSale)) },
			check: func(t *testing.T, e *testEnv, page string) {
				if want := tierDiscount(25); !strings.Contains(page, want) {
					t.Errorf("want %s", want)
				}
			}},
		{name: "a card the sale leaves out", hits: bothHits, server: search, searched: 1,
			setup: func(t *testing.T, conn *sql.DB) {
				sale(t, conn, nil, nil)
				insertExcludedProduct(t, conn, 1_792_611, saleID, other)
			},
			want: func(e *testEnv) string { return section(e, 2, saleCard(e, 300, "")) }},
		// A live default code of the card's own wins over the sale, and carries no sale label.
		{name: "a card's default code over the sale", hits: bothHits, server: search, searched: 1,
			setup: func(t *testing.T, conn *sql.DB) {
				sale(t, conn, map[string]any{"default_offer_code_id": 1_792_602}, nil)
				insertOfferCode(t, conn, 1_792_602, map[string]any{"code": "LAUNCH", "amount_cents": 50})
			},
			want: func(e *testEnv) string { return section(e, 2, saleCard(e, 250, `,"original_price_cents":300`)) }},
		{name: "a card's expired default code under the sale", hits: bothHits, server: search, searched: 1,
			setup: func(t *testing.T, conn *sql.DB) {
				sale(t, conn, map[string]any{"default_offer_code_id": 1_792_602}, nil)
				insertOfferCode(t, conn, 1_792_602, map[string]any{"code": "LAUNCH", "amount_cents": 50, "expires_at": testNow.Add(-time.Hour)})
			},
			want: func(e *testEnv) string { return section(e, 2, saleCard(e, 270, onSale)) }},
		// The default code is the sale itself, loaded twice; Rails compares them as records.
		{name: "a card whose default code is the sale", hits: bothHits, server: search, searched: 1,
			setup: func(t *testing.T, conn *sql.DB) { sale(t, conn, map[string]any{"default_offer_code_id": saleID}, nil) },
			want:  func(e *testEnv) string { return section(e, 2, saleCard(e, 270, onSale)) }},
		{name: "a card's limited default code with uses left over the sale", hits: bothHits, server: search, searched: 1,
			setup: func(t *testing.T, conn *sql.DB) {
				sale(t, conn, map[string]any{"default_offer_code_id": 1_792_602}, nil)
				insertOfferCode(t, conn, 1_792_602, map[string]any{"code": "LAUNCH", "amount_cents": 50, "max_purchase_count": 2})
				insertCodeUse(t, conn, 1_792_651, 1_792_602, map[string]any{"link_id": other})
			},
			want: func(e *testEnv) string { return section(e, 2, saleCard(e, 250, `,"original_price_cents":300`)) }},
		{name: "a card's used-up default code under the sale", hits: bothHits, server: search, searched: 1,
			setup: func(t *testing.T, conn *sql.DB) {
				sale(t, conn, map[string]any{"default_offer_code_id": 1_792_602}, nil)
				insertOfferCode(t, conn, 1_792_602, map[string]any{"code": "LAUNCH", "amount_cents": 50, "max_purchase_count": 1})
				insertCodeUse(t, conn, 1_792_651, 1_792_602, map[string]any{"link_id": other})
			},
			want: func(e *testEnv) string { return section(e, 2, saleCard(e, 270, onSale)) }},
		// discounted_price_cents quotes no sale this product alone can't meet.
		{name: "a sale over the card's price", hits: bothHits, server: search, searched: 1,
			setup: func(t *testing.T, conn *sql.DB) { sale(t, conn, nil, map[string]any{"minimum_amount_cents": 301}) },
			want:  func(e *testEnv) string { return section(e, 2, saleCard(e, 300, "")) }},
		{name: "a limited sale with uses left on a card", hits: bothHits, server: search, searched: 1,
			setup: func(t *testing.T, conn *sql.DB) {
				sale(t, conn, nil, map[string]any{"max_purchase_count": 2})
				insertCodeUse(t, conn, 1_792_651, saleID, nil)
			},
			want: func(e *testEnv) string { return section(e, 2, saleCard(e, 270, onSale)) }},
		{name: "a used-up sale on a card", hits: bothHits, server: search, searched: 1,
			setup: func(t *testing.T, conn *sql.DB) {
				sale(t, conn, nil, map[string]any{"max_purchase_count": 1})
				insertCodeUse(t, conn, 1_792_651, saleID, nil)
			},
			want: func(e *testEnv) string { return section(e, 2, saleCard(e, 300, "")) }},
		// discounts_lowest_priced_option?: the sale covers the card's cheapest option, one without a
		// difference, which the nil minimum equals.
		{name: "a sale scoped to the card's cheapest option", hits: bothHits, server: search, searched: 1,
			setup: func(t *testing.T, conn *sql.DB) { scopedSale(t, conn, 0, nil) },
			want:  func(e *testEnv) string { return section(e, 2, saleCard(e, 270, onSale)) }},
		{name: "a sale scoped to the cheaper of two options", hits: bothHits, server: search, searched: 1,
			setup: func(t *testing.T, conn *sql.DB) { scopedSale(t, conn, 0, 0, 100) },
			want:  func(e *testEnv) string { return section(e, 2, saleCard(e, 270, onSale)) }},
		// restricted_variants_for finds none of this product's, so the sale applies.
		{name: "a sale scoped to another product's option", hits: bothHits, server: search, searched: 1,
			setup: func(t *testing.T, conn *sql.DB) {
				sale(t, conn, nil, nil)
				insertExcludedProduct(t, conn, 1_792_611, saleID, productID)
				testdb.Insert(t, conn, "variant_categories", map[string]any{"id": category, "link_id": productID, "title": "Size"})
				testdb.Insert(t, conn, "base_variants", map[string]any{"id": int64(1_792_631), "type": "Variant", "variant_category_id": category,
					"name": "V", "created_at": testNow, "updated_at": testNow})
				testdb.Insert(t, conn, "offer_codes_variants", map[string]any{"id": int64(1_792_621), "offer_code_id": saleID,
					"variant_id": int64(1_792_631)})
			},
			want: func(e *testEnv) string { return section(e, 2, saleCard(e, 270, onSale)) }},
		// It covers only a pricier option, so the card quotes the cheapest undiscounted.
		{name: "a sale scoped to a pricier option", hits: bothHits, server: search, searched: 1,
			setup: func(t *testing.T, conn *sql.DB) { scopedSale(t, conn, 1, 0, 100) },
			want:  func(e *testEnv) string { return section(e, 2, saleCard(e, 300, "")) }},
		{name: "a sale scoped to a tier", reason: "catalog offer code tiers", hits: bothHits, server: search, searched: 1,
			setup: func(t *testing.T, conn *sql.DB) {
				tieredOther(t, conn)
				insertOfferCode(t, conn, saleID, map[string]any{"code": "SALE", "amount_percentage": 10, "universal": true, "auto_apply": true})
				insertExcludedProduct(t, conn, 1_792_611, saleID, productID)
				testdb.Insert(t, conn, "offer_codes_variants", map[string]any{"id": int64(1_792_621), "offer_code_id": saleID,
					"variant_id": category + 1})
			}},
		// 270 and 300 cents through 0.92345.
		{name: "a card's sale in the buyer's currency", hits: bothHits, server: search, searched: 1, headers: eurCookie,
			setup:   func(t *testing.T, conn *sql.DB) { sale(t, conn, nil, nil) },
			prepare: func(e *testEnv) { e.localEUR("0.92345") },
			want: func(e *testEnv) string {
				return strings.Replace(saleCard(e, 270, onSale), `"buyer_currency_shown":"usd","product_currency":"usd",`+
					`"buyer_local_price_cents":null,"rate":null,"display_mode":"default"}`, `"buyer_currency_shown":"eur","product_currency":"usd",`+
					`"buyer_local_price_cents":249,"rate":0.92345,"display_mode":"buyer_local"},"buyer_currency":"eur","buyer_local_currency_rate":0.92345,`+
					`"buyer_local_currency_subunit_to_unit":100,"buyer_local_price_cents":249,"buyer_local_original_price_cents":277`, 1)
			}},
		{name: "a rental card", hits: bothHits, server: search, searched: 1,
			setup: func(t *testing.T, conn *sql.DB) { rentable(t, conn, 1) },
			want:  func(e *testEnv) string { return section(e, 2, saleCard(e, 150, "")) }},
		{name: "a card to buy or rent", hits: bothHits, server: search, searched: 1,
			setup: func(t *testing.T, conn *sql.DB) { rentable(t, conn, 2) },
			want:  func(e *testEnv) string { return section(e, 2, saleCard(e, 300, "")) }},
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
			path := "/l/guide" + c.query
			headers := c.headers
			if c.signedIn {
				headers = e.signedIn(buyerID, nil)
			}
			w := e.get(host, path, e.withDryRun(path, headers, c.reason))
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
			var key string
			for _, k := range e.cache.writes {
				if strings.HasPrefix(k, "profile-sections_") {
					key = k
				}
			}
			// Searches write Rails' entry; an entry Rails cached is served as it is.
			if c.searched == 0 {
				if key != "" {
					t.Errorf("cache writes %v", e.cache.writes)
				}
				return
			}
			if e.cache.ttls[key] != 10*time.Minute {
				t.Fatalf("cache writes %v", e.cache.writes)
			}
			// The next view reads the search from the cache.
			again := html.UnescapeString(dataPage.FindStringSubmatch(e.get(host, path, headers).Body.String())[1])
			wantSearches := c.searched
			if c.searchedAgain != 0 {
				wantSearches = c.searchedAgain
			}
			if searches != wantSearches || !strings.Contains(again, c.want(e)) {
				t.Errorf("%d searches, want %d; same catalog %v", searches, wantSearches, strings.Contains(again, c.want(e)))
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
		// MySQL's JSON type sorts the keys, by length and then bytes.
		`{"text":{"content":[{"type":"text","text":"Hi <b>"}],"attrs":{"width":1.5},"type":"doc"}}`)
	addSection(t, conn, 1_792_604, "SellerProfileWishlistsSection", "Lists", `{"shown_wishlists":[1]}`)
	listSections(t, conn, `{"sections":[1792601,1792602,1792603],"main_section_index":1}`)
}

// productSectionsKey is cached_sections' key for the product's own sections, rows of them saved at
// testNow.
func productSectionsKey(e *testEnv, rows int64) string {
	h := &handler{c: e.config}
	products, err := h.readProductsCacheKey(context.Background(), sellerID)
	if err != nil {
		e.t.Fatal(err)
	}
	return h.sectionsCacheKey(products, productSectionsCacheKey(productID, rows, db.NullTime{Time: testNow, Valid: true}))
}

// productSectionsEntry is the entry Rails caches for addProductSections' sections, its products
// section finding shown.
func productSectionsEntry(e *testEnv, shown int64) []any {
	head := func(id int64, header, typ string) railscache.Hash {
		return railscache.Hash{{Key: railscache.Symbol("id"), Value: railscache.ASCII(e.ids.Encrypt(id))},
			{Key: railscache.Symbol("header"), Value: header}, {Key: railscache.Symbol("type"), Value: typ}}
	}
	products := railsCachedSection(e.ids.Encrypt(1_792_602), "More", "newest", 1, shown)
	products[5].Value.(railscache.Hash)[2].Value = []any{railscache.Hash{{Key: "key", Value: "pdf"}, {Key: "doc_count", Value: int64(2)}}}
	return []any{
		append(head(1_792_601, "Join", profileSubscribeSectionType), railscache.Pair{Key: railscache.Symbol("button_label"), Value: "Subscribe"}),
		products,
		append(head(1_792_603, "About", profileRichTextSectionType), railscache.Pair{Key: railscache.Symbol("text"), Value: railscache.Hash{
			{Key: "type", Value: "doc"},
			{Key: "attrs", Value: railscache.Hash{{Key: "width", Value: 1.5}}},
			{Key: "content", Value: []any{railscache.Hash{{Key: "text", Value: "Hi <b>"}, {Key: "type", Value: "text"}}}},
		}}),
		append(head(1_792_604, "Lists", profileWishlistsSectionType),
			railscache.Pair{Key: railscache.Symbol("shown_wishlists"), Value: []any{railscache.ASCII(e.ids.Encrypt(1))}}),
	}
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

func railsSectionsKey(e *testEnv, virtual bool) string {
	h := &handler{c: e.config}
	ctx := context.Background()
	products, err := h.readProductsCacheKey(ctx, sellerID)
	if err != nil {
		e.t.Fatal(err)
	}
	if virtual {
		return "profile-sections_default_test-" + products
	}
	sections, err := h.savedProductsSections(ctx, sellerID)
	if err != nil {
		e.t.Fatal(err)
	}
	return "profile-sections_test-" + products + "-" + profileSectionsCacheKey(sellerID, sections)
}

// The key Rails gave a production seller's two sections, the later saved at 19:58:07.957624.
func TestProfileSectionsCacheKey(t *testing.T) {
	at := func(s string) db.NullTime {
		v, err := time.Parse(time.RFC3339Nano, s)
		if err != nil {
			t.Fatal(err)
		}
		return db.NullTime{Time: v, Valid: true}
	}
	sections := []*productsSection{{updatedAt: at("2026-11-04T19:58:07.957624Z")}, {updatedAt: at("2026-10-01T08:00:00Z")}}
	want := "seller_profile_products_sections/query-72c9c98aeb41f680791a94a5f360b55c-2-20261104195807957624"
	if got := profileSectionsCacheKey(7499319, sections); got != want {
		t.Errorf("got %s, want %s", got, want)
	}
}

// railsCachedSection is a products section as cached_sections Marshals it: an external id is
// US-ASCII, as Base64 leaves it.
func railsCachedSection(id string, header any, sort string, total int64, ids ...int64) railscache.Hash {
	products := make([]any, len(ids))
	for i, id := range ids {
		products[i] = strconv.FormatInt(id, 10)
	}
	return railscache.Hash{
		{Key: railscache.Symbol("id"), Value: railscache.ASCII(id)},
		{Key: railscache.Symbol("header"), Value: header},
		{Key: railscache.Symbol("type"), Value: profileProductsSectionType},
		{Key: railscache.Symbol("show_filters"), Value: false},
		{Key: railscache.Symbol("default_product_sort"), Value: sort},
		{Key: railscache.Symbol("search_results"), Value: railscache.Hash{
			{Key: railscache.Symbol("total"), Value: total},
			{Key: railscache.Symbol("tags_data"), Value: []any{railscache.Hash{{Key: "key", Value: "design"}, {Key: "doc_count", Value: int64(2)}}}},
			{Key: railscache.Symbol("filetypes_data"), Value: []any{}},
			{Key: railscache.Symbol("taxonomy_attributes_data"), Value: []any{}},
			{Key: railscache.Symbol("products"), Value: products},
		}},
	}
}

// A posts section lists the seller's shown posts that are published on the profile, newest
// first, ties by id.
func TestAProductPostsSection(t *testing.T) {
	e := newTestEnv(t)
	conn := testdb.Open(t)
	post := func(id int64, published any, flags int64, columns map[string]any) {
		row := map[string]any{"id": id, "seller_id": sellerID, "name": fmt.Sprintf("Post %d", id), "slug": fmt.Sprintf("post-%d", id),
			"installment_type": "audience", "flags": flags, "published_at": published, "created_at": testNow, "updated_at": testNow}
		for k, v := range columns {
			row[k] = v
		}
		testdb.Insert(t, conn, "installments", row)
	}
	const shown = installmentShownOnProfile
	post(1_795_501, testNow.Add(-time.Hour), shown, nil)
	post(1_795_502, testNow, shown, nil)
	post(1_795_503, testNow, shown, nil)
	post(1_795_504, nil, shown, nil)
	post(1_795_505, testNow, 0, nil)
	post(1_795_506, testNow, shown, map[string]any{"deleted_at": testNow})
	post(1_795_507, testNow, shown, map[string]any{"installment_type": "follower"})
	post(1_795_508, testNow, shown, map[string]any{"workflow_id": int64(1)})
	post(1_795_509, testNow, shown, map[string]any{"seller_id": int64(1)})
	addSection(t, conn, 1_792_611, profilePostsSectionType, "News",
		`{"shown_posts":[1795501,1795502,1795503,1795504,1795505,1795506,1795507,1795508,1795509]}`)
	addSection(t, conn, 1_792_612, profilePostsSectionType, "Empty", `{"shown_posts":[]}`)
	listSections(t, conn, `{"sections":[1792611,1792612]}`)

	w := e.get(host, "/l/guide", nil)
	if w.Code != http.StatusOK || e.railsHit != nil {
		t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
	page := html.UnescapeString(dataPage.FindStringSubmatch(w.Body.String())[1])
	entry := func(id int64, at string) string {
		return fmt.Sprintf(`{"id":"%s","name":"Post %d","slug":"post-%d","published_at":"%s"}`, e.ids.Encrypt(id), id, id, at)
	}
	want := `"sections":[{"id":"` + e.ids.Encrypt(1_792_611) + `","header":"News","type":"SellerProfilePostsSection","posts":[` +
		entry(1_795_502, "2026-11-06T12:00:00Z") + "," + entry(1_795_503, "2026-11-06T12:00:00Z") + "," + entry(1_795_501, "2026-11-06T11:00:00Z") +
		`]},{"id":"` + e.ids.Encrypt(1_792_612) + `","header":"Empty","type":"SellerProfilePostsSection","posts":[]}]`
	if !strings.Contains(page, want) {
		t.Errorf("want %s\nin %s", want, page)
	}
}

// A featured section renders its product's product_props within the page, as the page renders
// its own; a product that isn't the seller's alive one renders none.
func TestAFeaturedProductSection(t *testing.T) {
	const featured = int64(1_795_601)
	e := newTestEnv(t)
	conn := testdb.Open(t)
	testdb.Insert(t, conn, "links", map[string]any{"id": featured, "user_id": sellerID, "name": "Featured", "unique_permalink": "gowebfp",
		"price_cents": 700, "created_at": testNow, "updated_at": testNow})
	testdb.Insert(t, conn, "prices", map[string]any{"id": int64(1_795_602), "link_id": featured, "price_cents": 700, "currency": "usd",
		"created_at": testNow, "updated_at": testNow})
	addSection(t, conn, 1_792_621, profileFeaturedSectionType, "Pick", fmt.Sprintf(`{"featured_product_id":%d}`, featured))
	addSection(t, conn, 1_792_622, profileFeaturedSectionType, "Gone", `{"featured_product_id":"1795699"}`)
	// seller.products.alive leaves out a deleted, banned or unpublished product, and another seller's.
	for i, columns := range []map[string]any{{"deleted_at": testNow}, {"banned_at": testNow}, {"purchase_disabled_at": testNow}, {"user_id": int64(1)}} {
		id := featured + 10 + int64(i)
		row := map[string]any{"id": id, "user_id": sellerID, "name": "Hidden", "unique_permalink": fmt.Sprintf("gowebh%d", i),
			"price_cents": 100, "created_at": testNow, "updated_at": testNow}
		for k, v := range columns {
			row[k] = v
		}
		testdb.Insert(t, conn, "links", row)
		addSection(t, conn, 1_792_630+int64(i), profileFeaturedSectionType, "Hidden", fmt.Sprintf(`{"featured_product_id":%d}`, id))
	}
	// A decimal String finds the product as the Integer does.
	addSection(t, conn, 1_792_623, profileFeaturedSectionType, "Again", fmt.Sprintf(`{"featured_product_id":"%d"}`, featured))
	listSections(t, conn, `{"sections":[1792621,1792622,1792630,1792631,1792632,1792633,1792623]}`)

	w := e.get(host, "/l/guide", nil)
	if w.Code != http.StatusOK || e.railsHit != nil {
		t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
	page := html.UnescapeString(dataPage.FindStringSubmatch(w.Body.String())[1])
	id := e.ids.Encrypt(featured)
	for _, want := range []string{
		`"sections":[{"id":"` + e.ids.Encrypt(1_792_621) + `","header":"Pick","type":"SellerProfileFeaturedProductSection",` +
			`"props":{"product":{"id":"` + id + `","permalink":"gowebfp","name":"Featured",`,
		`"price_cents":700,`,
		`"long_url":"https://gowebproductseller.gumroad.com/l/gowebfp",`,
		`},"discount_code":null,"sale_label":null,`,
		`"purchase":null,"wishlists":[]}},{"id":"` + e.ids.Encrypt(1_792_622) + `","header":"Gone","type":"SellerProfileFeaturedProductSection","props":null},`,
		`"header":"Hidden","type":"SellerProfileFeaturedProductSection","props":null},{"id":"` + e.ids.Encrypt(1_792_631),
		`"header":"Hidden","type":"SellerProfileFeaturedProductSection","props":null},{"id":"` + e.ids.Encrypt(1_792_633) +
			`","header":"Hidden","type":"SellerProfileFeaturedProductSection","props":null},{"id":"` + e.ids.Encrypt(1_792_623) +
			`","header":"Again","type":"SellerProfileFeaturedProductSection","props":{"product":{"id":"` + id + `"`,
	} {
		if !strings.Contains(page, want) {
			t.Errorf("want %s", want)
		}
	}
}

// A coffee product's props are any product's: only show redirects it, and only as the page.
func TestAFeaturedCoffeeProduct(t *testing.T) {
	const coffee, amounts, suggested = int64(1_795_701), int64(1_795_702), int64(1_795_703)
	e := newTestEnv(t)
	conn := testdb.Open(t)
	// initialize_suggested_amount_if_needed!'s shape: a $0 base, pay what you want, and a nameless option.
	testdb.Insert(t, conn, "links", map[string]any{"id": coffee, "user_id": sellerID, "name": "Tip jar", "unique_permalink": "gowebtip",
		"native_type": "coffee", "price_cents": 0, "customizable_price": true, "created_at": testNow, "updated_at": testNow})
	testdb.Insert(t, conn, "prices", map[string]any{"id": int64(1_795_704), "link_id": coffee, "price_cents": 0, "currency": "usd",
		"created_at": testNow, "updated_at": testNow})
	testdb.Insert(t, conn, "variant_categories", map[string]any{"id": amounts, "link_id": coffee, "title": "Suggested Amounts"})
	testdb.Insert(t, conn, "base_variants", map[string]any{"id": suggested, "type": "Variant", "variant_category_id": amounts, "name": "",
		"price_difference_cents": 300, "created_at": testNow, "updated_at": testNow})
	addSection(t, conn, 1_792_641, profileFeaturedSectionType, "Tip", `{"featured_product_id":1795701}`)
	listSections(t, conn, `{"sections":[1792641]}`)
	page := e.render(t, nil, "")
	for _, want := range []string{
		`"header":"Tip","type":"SellerProfileFeaturedProductSection","props":{"product":{"id":"` + e.ids.Encrypt(coffee) + `","permalink":"gowebtip","name":"Tip jar",`,
		`"native_type":"coffee",`,
		`"options":[{"id":"` + e.ids.Encrypt(suggested) + `","name":"","quantity_left":null,"description":"","price_difference_cents":300,`,
	} {
		if !strings.Contains(page, want) {
			t.Errorf("want %s", want)
		}
	}
}

// Rails builds an unlisted featured section's product_props too, so its product's shape counts.
func TestAnUnlistedFeaturedSectionsProduct(t *testing.T) {
	e := newTestEnv(t)
	conn := testdb.Open(t)
	testdb.Insert(t, conn, "links", map[string]any{"id": int64(1_795_711), "user_id": sellerID, "name": "Odd", "unique_permalink": "gowebodd",
		"purchase_type": 3, "price_cents": 100, "created_at": testNow, "updated_at": testNow})
	addSection(t, conn, 1_792_642, profileFeaturedSectionType, "Odd", `{"featured_product_id":1795711}`)
	listSections(t, conn, `{"sections":[]}`)
	e.render(t, nil, "purchase type")
}

// The sections' keys embed the REVISION Rails.cache is namespaced under, which go_web follows.
func TestSectionsCacheKeyFollowsRailsRevision(t *testing.T) {
	h := &handler{c: &Config{Env: &web.Environment{Revision: "go"}, Page: &PageConfig{}}}
	if got := h.sectionsCacheKey("p", "r"); got != "profile-sections_go-p-r" {
		t.Errorf("before Rails answers: %q", got)
	}
	h.c.Page.Revision = func() string { return "rails" }
	if got := h.sectionsCacheKey("p", "r"); got != "profile-sections_rails-p-r" {
		t.Errorf("following Rails: %q", got)
	}
}
