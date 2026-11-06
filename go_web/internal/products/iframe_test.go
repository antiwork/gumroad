package products

import (
	"database/sql"
	"html"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"

	"github.com/antiwork/gumroad/go_web/internal/elastic"
	"github.com/antiwork/gumroad/go_web/internal/session/testdb"
)

// An embed or overlay renders Products/Iframe/Show with product_props alone, whatever sections
// the product has, under an iframe body class. Rails tests the param for truthiness, so a blank
// value counts and a bare key, which parses to nil, doesn't.
func TestTheIframeEmbed(t *testing.T) {
	for _, c := range []struct {
		target string
		iframe bool
	}{
		{"/l/guide?embed=true", true},
		{"/l/guide?overlay=true", true},
		{"/l/guide?embed=", true},
		{"/l/guide?overlay=false", true},
		{"/l/guide?embed[]=1", true},
		{"/l/guide?embed", false},
	} {
		t.Run(c.target, func(t *testing.T) {
			e := newTestEnv(t)
			addProductSections(t, testdb.Open(t), 0)
			w := e.get(host, c.target, nil)
			if w.Code != http.StatusOK || e.railsHit != nil {
				t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
			}
			body := w.Body.String()
			if !c.iframe {
				componentProps(t, body, productComponent)
				if !strings.Contains(body, `<body id="product_page" class="group/body mac" style="">`) {
					t.Error("body tag")
				}
				return
			}
			props := componentProps(t, body, iframeComponent)
			for _, key := range []string{"sections", "main_section_index", "creator_profile", "currency_code", "show_ratings_filter"} {
				if _, ok := props[key]; ok {
					t.Errorf("%s in the iframe's props", key)
				}
			}
			for _, key := range []string{"product", "discount_code", "purchase", "wishlists"} {
				if _, ok := props[key]; !ok {
					t.Errorf("no %s in the iframe's props", key)
				}
			}
			if !strings.Contains(body, `<body id="product_page" class="group/body mac iframe" style="">`) {
				t.Error("body tag")
			}
			// prepare_product_page's meta tags still read the seller's styles.
			if !strings.Contains(html.UnescapeString(body), `<style inertia="custom_styles">`+defaultStyles(t)+`</style>`) {
				t.Error("custom styles")
			}
		})
	}
}

// The iframe wins over the storefront, and reads none of the sections Rails leaves unbuilt.
func TestAStorefrontEmbedSkipsTheCatalog(t *testing.T) {
	e := newTestEnv(t)
	conn := testdb.Open(t)
	mustExec(t, conn, "UPDATE users SET flags = flags | ? WHERE id = ?", userProductPageStorefrontEnabled, sellerID)
	// A section row Rails would raise on is no fallback when it builds no sections.
	testdb.Insert(t, conn, "seller_profile_sections", map[string]any{"id": int64(1_799_101), "seller_id": sellerID,
		"product_id": productID, "type": profileSubscribeSectionType, "json_data": nil, "created_at": testNow, "updated_at": testNow})
	var searches int
	search := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		searches++
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer search.Close()
	client, err := elastic.NewWithClient(search.URL, search.Client())
	if err != nil {
		t.Fatal(err)
	}
	e.config.Page.Search = client
	// product_props still reads the sales count.
	mustExec(t, conn, "UPDATE links SET flags = flags | ? WHERE id = ?", productShouldShowSalesCount, productID)
	price := int64(500)
	e.cache.values[salesCountKey(productID, &price, sql.NullInt64{})] = int64(17)
	// product_props reads the reputation snapshot; only creator_profile reads the cached rollup.
	e.redis.HSet("seller_reputation_summary", "boolean", "true")
	e.redis.Set("seller_reputation_summary/v2/snapshot/1790001",
		`{"aggregate":[3,30,120],"signature":0,"computed_at":`+strconv.FormatInt(testNow.Unix(), 10)+`}`)
	w := e.get(host, "/l/guide?embed=true", nil)
	if w.Code != http.StatusOK || e.railsHit != nil {
		t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
	props := componentProps(t, w.Body.String(), iframeComponent)
	if searches != 0 || len(e.cache.writes) != 0 {
		t.Errorf("%d searches, cache writes %v", searches, e.cache.writes)
	}
	if _, ok := props["product"].(map[string]any)["seller_reputation"]; !ok {
		t.Error("no seller_reputation")
	}
	if _, ok := props["sections"]; ok {
		t.Error("sections in the iframe's props")
	}
	if n := props["product"].(map[string]any)["sales_count"]; n != float64(17) {
		t.Errorf("sales_count %v", n)
	}
}
