package products

import (
	"database/sql"
	"fmt"
	"html"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/elastic"
	"github.com/antiwork/gumroad/go_web/internal/session/testdb"
)

const ownOther = int64(1_799_001)

// signInSeller makes the product's seller a user who can sign in, and returns their session.
func signInSeller(t *testing.T, e *testEnv, conn *sql.DB) map[string]string {
	mustExec(t, conn, "UPDATE users SET email = 'seller@example.com', confirmed_at = ?, timezone = 'Pacific Time (US & Canada)' WHERE id = ?",
		testNow, sellerID)
	return e.signedIn(sellerID, nil)
}

// ownSearch answers every products search with the other product and this one.
func ownSearch(t *testing.T, e *testEnv) *int {
	searches := new(int)
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		*searches++
		io.WriteString(w, fmt.Sprintf(`{"hits":{"total":{"value":2,"relation":"eq"},"hits":[{"_id":"%d","sort":[1762430000000,1762430000000]},`+
			`{"_id":"%d","sort":[1762420000000,1762420000000]}]},"aggregations":{"tags.keyword":{"buckets":[]},"filetypes.keyword":{"buckets":[]}}}`,
			ownOther, productID))
	}))
	t.Cleanup(server.Close)
	client, err := elastic.NewWithClient(server.URL, server.Client())
	if err != nil {
		t.Fatal(err)
	}
	e.config.Page.Search = client
	return searches
}

// The seller's own view: can_edit, the waitlist's count, the sections in the editor's shape with
// the editor's lists after them, and the standalone page though the storefront is on.
func TestTheSellersOwnView(t *testing.T) {
	e := newTestEnv(t)
	conn := testdb.Open(t)
	headers := signInSeller(t, e, conn)
	searches := ownSearch(t, e)
	mustExec(t, conn, "UPDATE users SET flags = flags | ? WHERE id = ?", userProductPageStorefrontEnabled, sellerID)
	mustExec(t, conn, "UPDATE links SET flags = flags | ?, draft = true WHERE id = ?", productWaitlistEnabled, productID)

	// A sold-out product hides from visitors, not from the seller.
	testdb.Insert(t, conn, "links", map[string]any{"id": ownOther, "user_id": sellerID, "name": "Other", "unique_permalink": "gowebown2",
		"price_cents": 300, "max_purchase_count": 0, "flags": productHideSoldOutVariants, "created_at": testNow, "updated_at": testNow})
	testdb.Insert(t, conn, "prices", map[string]any{"id": int64(1_799_002), "link_id": ownOther, "price_cents": 300, "currency": "usd",
		"created_at": testNow, "updated_at": testNow})
	// The editor lists alive products that aren't archived.
	for i, columns := range []map[string]any{{"flags": productArchived}, {"deleted_at": testNow}} {
		row := map[string]any{"id": int64(1_799_003 + i), "user_id": sellerID, "name": "Hidden", "unique_permalink": fmt.Sprintf("gowebownh%d", i),
			"price_cents": 100, "created_at": testNow, "updated_at": testNow}
		for k, v := range columns {
			row[k] = v
		}
		testdb.Insert(t, conn, "links", row)
	}

	// Only an active follower's entry counts.
	for i, columns := range []map[string]any{{"confirmed_at": testNow}, {}, {"confirmed_at": testNow, "deleted_at": testNow}} {
		follower := int64(1_799_011 + i)
		row := map[string]any{"id": follower, "followed_id": sellerID, "email": fmt.Sprintf("f%d@example.com", i), "created_at": testNow, "updated_at": testNow}
		for k, v := range columns {
			row[k] = v
		}
		testdb.Insert(t, conn, "followers", row)
		testdb.Insert(t, conn, "waitlist_entries", map[string]any{"id": int64(1_799_021 + i), "follower_id": follower, "product_id": productID,
			"created_at": testNow, "updated_at": testNow})
	}

	post := func(id int64, published time.Time, flags int64) {
		testdb.Insert(t, conn, "installments", map[string]any{"id": id, "seller_id": sellerID, "name": fmt.Sprintf("Post %d", id),
			"slug": fmt.Sprintf("post-%d", id), "installment_type": "audience", "flags": flags, "published_at": published,
			"created_at": testNow, "updated_at": testNow})
	}
	post(1_799_031, testNow.Add(-time.Hour), installmentShownOnProfile)
	post(1_799_032, testNow, installmentShownOnProfile)
	post(1_799_033, testNow, 0)

	testdb.Insert(t, conn, "wishlists", map[string]any{"id": int64(1_799_041), "user_id": sellerID, "name": "Gifts",
		"created_at": testNow, "updated_at": testNow})
	testdb.Insert(t, conn, "wishlists", map[string]any{"id": int64(1_799_042), "user_id": sellerID, "name": "Gone", "deleted_at": testNow,
		"created_at": testNow, "updated_at": testNow})

	addSection(t, conn, 1_799_051, profileProductsSectionType, "More", fmt.Sprintf(
		`{"shown_products":[%d,%d],"default_product_sort":"newest","show_filters":false,"add_new_products":true}`, ownOther, productID))
	addSection(t, conn, 1_799_052, profilePostsSectionType, "", `{"shown_posts":[1799031,1799032,1799033]}`)
	// The editor names a featured product without loading it, so one whose props go to Rails is no
	// fallback.
	testdb.Insert(t, conn, "links", map[string]any{"id": int64(1_799_006), "user_id": sellerID, "name": "Odd", "unique_permalink": "gowebownc",
		"purchase_type": 3, "price_cents": 100, "created_at": testNow, "updated_at": testNow})
	addSection(t, conn, 1_799_053, profileFeaturedSectionType, "Pick", `{"featured_product_id":1799006}`)
	addSection(t, conn, 1_799_054, profileRichTextSectionType, "About", `{"text":{"type":"doc","content":[]}}`)
	addSection(t, conn, 1_799_055, profileWishlistsSectionType, "Lists", `{"shown_wishlists":[]}`)
	addSection(t, conn, 1_799_056, profileSubscribeSectionType, "Join", `{"button_label":"Subscribe"}`)
	listSections(t, conn, `{"sections":[1799051,1799052,1799053,1799054,1799055,1799056]}`)
	// The editor shows a hidden header, and a missing one as "".
	mustExec(t, conn, "UPDATE seller_profile_sections SET flags = ? WHERE id IN (1799051, 1799054)", sectionHiddenHeader)
	mustExec(t, conn, "UPDATE seller_profile_sections SET header = NULL WHERE id = 1799052")

	w := e.get(host, "/l/guide", headers)
	if w.Code != http.StatusOK || e.railsHit != nil {
		t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
	if *searches != 1 {
		t.Errorf("%d searches, want the section's alone", *searches)
	}
	componentProps(t, w.Body.String(), productComponent)
	page := html.UnescapeString(dataPage.FindStringSubmatch(w.Body.String())[1])
	entry := func(id int64, at string) string {
		return fmt.Sprintf(`{"id":"%s","name":"Post %d","slug":"post-%d","published_at":"%s"}`, e.ids.Encrypt(id), id, id, at)
	}
	e.wantAll(t, page, []string{
		`"can_edit":true,"waitlist":{"recaptcha_site_key":null,"count":1},`,
		`"is_verified":false,"can_edit":true,`,
		`"sections":[{"id":"%[1]s","header":"More","type":"SellerProfileProductsSection","show_filters":false,"default_product_sort":"newest",` +
			`"search_results":{"total":2,"tags_data":[],"filetypes_data":[],"taxonomy_attributes_data":[],"products":[{"id":"%[2]s","permalink":"gowebown2",`,
		`]},"hide_header":true,"shown_products":["%[2]s","%[3]s"],"add_new_products":true},` +
			`{"id":"%[4]s","header":"","type":"SellerProfilePostsSection","hide_header":false,"shown_posts":["%[5]s","%[6]s"]},` +
			`{"id":"%[7]s","header":"Pick","type":"SellerProfileFeaturedProductSection","featured_product_id":"%[8]s","hide_header":false},` +
			`{"id":"%[9]s","header":"About","type":"SellerProfileRichTextSection","text":{"type":"doc","content":[]},"hide_header":true},` +
			`{"id":"%[10]s","header":"Lists","type":"SellerProfileWishlistsSection","shown_wishlists":[],"hide_header":false,"wishlists":[]},` +
			`{"id":"%[12]s","header":"Join","type":"SellerProfileSubscribeSection","button_label":"Subscribe","hide_header":false}],` +
			`"products":[{"id":"%[3]s","name":"Guide \u003c1\u003e"},{"id":"%[2]s","name":"Other"},{"id":"%[8]s","name":"Odd"}],` +
			`"posts":[` + entry(1_799_032, "2026-11-06T12:00:00Z") + `,` + entry(1_799_031, "2026-11-06T11:00:00Z") + `],` +
			`"wishlist_options":[{"id":"%[11]s","name":"Gifts"}],"main_section_index":0`,
	}, 1_799_051, ownOther, productID, 1_799_052, 1_799_032, 1_799_031, 1_799_053, 1_799_006, 1_799_054, 1_799_055, 1_799_041, 1_799_056)
}

// Rails shows the seller and collaborators the custom HTML page of an unpublished product, even a
// coffee one, which show would redirect, with the live reload. Any other signed-in visitor gets
// the standard page.
func TestTheSellerPreviewsTheirCustomHTML(t *testing.T) {
	for _, c := range []struct {
		name          string
		coffee, buyer bool
	}{
		{name: "the seller"},
		{name: "the seller of a coffee product", coffee: true},
		{name: "another visitor", buyer: true},
	} {
		t.Run(c.name, func(t *testing.T) {
			e := newTestEnv(t)
			conn := testdb.Open(t)
			headers := signInSeller(t, e, conn)
			if c.buyer {
				addBuyer(t, conn, nil)
				headers = e.signedIn(buyerID, nil)
			}
			mustExec(t, conn, "UPDATE links SET purchase_disabled_at = ? WHERE id = ?", testNow, productID)
			if c.coffee {
				mustExec(t, conn, "UPDATE links SET native_type = 'coffee' WHERE id = ?", productID)
			}
			customHTML(t, e, conn)
			body := e.render(t, headers, "")
			wrapper := strings.Contains(body, "gumroad-landing-frame") && strings.Contains(body, `var versionUrl = "/l/gowebp1/landing/version";`)
			if c.buyer && (wrapper || !strings.Contains(body, productComponent)) {
				t.Error("not the standard page")
			}
			if !c.buyer && !wrapper {
				t.Error("not the preview")
			}
		})
	}
}
