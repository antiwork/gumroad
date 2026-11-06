package products

import (
	"database/sql"
	"fmt"
	"html"
	"net/http"
	"strings"
	"testing"

	"github.com/antiwork/gumroad/go_web/internal/session/testdb"
)

// A wishlists section renders the alive shown wishlists' cards in shown_wishlists order, each
// with its last product's thumbnail, or its last four's when it has four.
func TestAProductWishlistsSection(t *testing.T) {
	const cafe, two, gone, buyers = int64(1_797_101), int64(1_797_102), int64(1_797_103), int64(1_797_104)
	setup := func(t *testing.T, conn *sql.DB) {
		addBuyer(t, conn, nil)
		wishlist := func(id, userID int64, name string, extra map[string]any) {
			row := map[string]any{"id": id, "user_id": userID, "name": name, "created_at": testNow, "updated_at": testNow}
			for k, v := range extra {
				row[k] = v
			}
			testdb.Insert(t, conn, "wishlists", row)
		}
		wishlist(cafe, sellerID, "Café  Picks!", map[string]any{"description": "Mine", "follower_count": 3})
		wishlist(two, sellerID, "Two", nil)
		wishlist(gone, sellerID, "Gone", map[string]any{"deleted_at": testNow})
		// NFC composes the accent before transliterating it.
		wishlist(buyers, buyerID, "étude", nil)
		for i, nativeType := range []string{"digital", "ebook", "audiobook", "course", "digital"} {
			testdb.Insert(t, conn, "links", map[string]any{"id": int64(1_797_201 + i), "user_id": sellerID, "name": "Listed",
				"unique_permalink": fmt.Sprintf("gowebw%d", i), "price_cents": 100, "native_type": nativeType,
				"created_at": testNow, "updated_at": testNow})
		}
		testdb.Insert(t, conn, "thumbnails", map[string]any{"id": int64(1_797_301), "product_id": int64(1_797_205),
			"unsplash_url": "https://images.unsplash.com/w", "created_at": testNow, "updated_at": testNow})
		item := func(id, wishlistID, productID int64, deletedAt any) {
			testdb.Insert(t, conn, "wishlist_products", map[string]any{"id": id, "wishlist_id": wishlistID, "product_id": productID,
				"quantity": 1, "rent": false, "deleted_at": deletedAt, "created_at": testNow, "updated_at": testNow})
		}
		for i := range int64(5) {
			item(1_797_401+i, cafe, 1_797_201+i, nil)
		}
		item(1_797_406, cafe, 1_797_201, testNow)
		// A product that's gone, outside the last four, only counts.
		item(1_797_400, cafe, 1_797_299, nil)
		item(1_797_407, two, 1_797_201, nil)
		item(1_797_408, two, 1_797_202, nil)
		addSection(t, conn, 1_792_641, profileWishlistsSectionType, "Lists", fmt.Sprintf(`{"shown_wishlists":[%d,%d,%d,%d]}`, two, buyers, gone, cafe))
		addSection(t, conn, 1_792_642, profileWishlistsSectionType, "None", `{"shown_wishlists":[]}`)
		listSections(t, conn, `{"sections":[1792641,1792642]}`)
	}
	thumb := func(nativeType string) string { return `{"url":null,"native_type":"` + nativeType + `"}` }
	sections := func(e *testEnv, avatar string, signedIn bool) string {
		byline := func(id, name, profile string) string {
			return fmt.Sprintf(`{"id":"%s","name":"%s","avatar_url":"%s","profile_url":"%s","is_verified":false}`, id, name, avatar, profile)
		}
		const sellerProfile, buyerProfile = "https://gowebproductseller.gumroad.com", "https://gowebbuyer.gumroad.com"
		seller, buyer := byline("1790001", "Seller", sellerProfile), byline("1796001", "Buyer", buyerProfile)
		card := func(id int64, profile, slug, name, description, byline, thumbnails string, products, followers int, following, canFollow bool) string {
			numeric, _ := e.ids.EncryptNumeric(id)
			return fmt.Sprintf(`{"id":"%s","url":"%s/wishlists/%s-%d?layout=profile","name":"%s","description":%s,"seller":%s,"thumbnails":[%s],`+
				`"product_count":%d,"follower_count":%d,"following":%t,"can_follow":%t}`, e.ids.Encrypt(id), profile, slug, numeric, name,
				description, byline, thumbnails, products, followers, following, canFollow)
		}
		return fmt.Sprintf(`"sections":[{"id":"%s","header":"Lists","type":"SellerProfileWishlistsSection","shown_wishlists":["%s","%s","%s","%s"],"wishlists":[`,
			e.ids.Encrypt(1_792_641), e.ids.Encrypt(two), e.ids.Encrypt(buyers), e.ids.Encrypt(gone), e.ids.Encrypt(cafe)) +
			card(two, sellerProfile, "two", "Two", "null", seller, thumb("ebook"), 2, 0, false, true) + "," +
			card(buyers, buyerProfile, "etude", "e\u0301tude", "null", buyer, "", 0, 0, false, !signedIn) + "," +
			card(cafe, sellerProfile, "cafe-picks", "Café  Picks!", `"Mine"`, seller, thumb("ebook")+","+thumb("audiobook")+","+thumb("course")+
				`,{"url":"https://images.unsplash.com/w","native_type":"digital"}`, 6, 3, signedIn, true) +
			`]},{"id":"` + e.ids.Encrypt(1_792_642) + `","header":"None","type":"SellerProfileWishlistsSection","shown_wishlists":[],"wishlists":[]}]`
	}

	for _, signedIn := range []bool{false, true} {
		t.Run(fmt.Sprintf("signed in %t", signedIn), func(t *testing.T) {
			e := newTestEnv(t)
			conn := testdb.Open(t)
			setup(t, conn)
			var headers map[string]string
			if signedIn {
				// pundit_user.seller follows one, and owns another.
				testdb.Insert(t, conn, "wishlist_followers", map[string]any{"id": int64(1_797_501), "wishlist_id": cafe,
					"follower_user_id": buyerID, "created_at": testNow, "updated_at": testNow})
				testdb.Insert(t, conn, "wishlist_followers", map[string]any{"id": int64(1_797_502), "wishlist_id": two,
					"follower_user_id": buyerID, "deleted_at": testNow, "created_at": testNow, "updated_at": testNow})
				headers = e.signedIn(buyerID, nil)
			}
			w := e.get(host, "/l/guide", headers)
			if w.Code != http.StatusOK || e.railsHit != nil {
				t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
			}
			body := w.Body.String()
			avatar := pageProps(t, body)["product"].(map[string]any)["seller"].(map[string]any)["avatar_url"].(string)
			page := html.UnescapeString(dataPage.FindStringSubmatch(body)[1])
			if want := sections(e, avatar, signedIn); !strings.Contains(page, want) {
				t.Errorf("want %s\nin %s", want, page)
			}
		})
	}
}

// A wishlists section goes to Rails, listed or not, where building its cards raises, and for
// a String id, which no section holds.
func TestAWishlistsSectionGoesToRails(t *testing.T) {
	for _, c := range []struct{ name, data, reason string }{
		{"no shown_wishlists", `{}`, "product section json_data"},
		{"a shown wishlist that isn't an id", `{"shown_wishlists":["1797601"]}`, "product section json_data"},
		{"a product that's gone", `{"shown_wishlists":[1797601]}`, "wishlist product"},
		{"a user that's gone", `{"shown_wishlists":[1797602]}`, "wishlist user"},
	} {
		t.Run(c.name, func(t *testing.T) {
			e := newTestEnv(t)
			conn := testdb.Open(t)
			testdb.Insert(t, conn, "wishlists", map[string]any{"id": int64(1_797_601), "user_id": sellerID, "name": "Missing",
				"created_at": testNow, "updated_at": testNow})
			testdb.Insert(t, conn, "wishlist_products", map[string]any{"id": int64(1_797_611), "wishlist_id": int64(1_797_601),
				"product_id": int64(1_797_699), "quantity": 1, "rent": false, "created_at": testNow, "updated_at": testNow})
			testdb.Insert(t, conn, "wishlists", map[string]any{"id": int64(1_797_602), "user_id": int64(1_797_698), "name": "Orphan",
				"created_at": testNow, "updated_at": testNow})
			addSection(t, conn, 1_792_651, profileWishlistsSectionType, "Lists", c.data)
			listSections(t, conn, `{"sections":[]}`)
			w := e.get(host, "/l/guide", e.dryRun(host, "/l/guide", testNow))
			if w.Code != http.StatusNoContent || w.Header().Get("X-Go-Web-Fallback") != c.reason {
				t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
			}
		})
	}
}
