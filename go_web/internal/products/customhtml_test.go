package products

import (
	"database/sql"
	"net/http"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/session/testdb"
)

const testAnalyticsScript = "https://assets.gumroad.com/vite/assets/entrypoints/custom_html_analytics.ts-T.js"

// customHTML turns on custom_html_pages and saves the product's root page.
func customHTML(t *testing.T, e *testEnv, conn *sql.DB) {
	e.redis.HSet("custom_html_pages", "boolean", "true")
	testdb.Insert(t, conn, "pages", map[string]any{"id": int64(1_795_401), "pageable_type": "Link", "pageable_id": productID,
		"custom_html": "<h1>x</h1>", "created_at": testNow, "updated_at": testNow})
}

var structuredDataScript = regexp.MustCompile(`<script type="application/ld\+json"[^>]*>([^<]*)</script>`)

// product_custom_html_wrapper_document, with the standard page's SEO signals around the
// sandboxed frame.
func TestTheCustomHTMLWrapper(t *testing.T) {
	e := newTestEnv(t)
	conn := testdb.Open(t)
	w := e.get(host, "/l/guide", nil)
	m := structuredDataScript.FindStringSubmatch(w.Body.String())
	if m == nil {
		t.Fatalf("no structured data on the standard page: %d", w.Code)
	}
	customHTML(t, e, conn)
	testdb.Insert(t, conn, "seller_profiles", map[string]any{"id": int64(1_795_402), "seller_id": sellerID, "background_color": "#ABCDEF",
		"created_at": testNow, "updated_at": testNow})

	w = e.get(host, "/l/guide", nil)
	if w.Code != http.StatusOK || e.railsHit != nil {
		t.Fatalf("%d %q, Rails hit: %v", w.Code, w.Header().Get("X-Go-Web-Fallback"), e.railsHit != nil)
	}
	body := w.Body.String()
	for _, want := range []string{
		"<!doctype html>\n<html lang=\"en\">\n  <head>\n",
		"    <title>Guide &lt;1&gt;</title>\n" +
			"    <link rel=\"canonical\" href=\"https://gowebproductseller.gumroad.com/l/guide\">\n" +
			"    <meta name=\"description\" content=\"Read https://example.com &amp; more\">\n" +
			"    <meta property=\"og:title\" content=\"Guide &lt;1&gt;\">\n",
		// No thumbnail or cover, so no image tags; the JSON-LD is the standard page's.
		"    <meta property=\"og:url\" content=\"https://gowebproductseller.gumroad.com/l/guide\">\n    \n" +
			"    <script type=\"application/ld+json\">" + m[1] + "</script>\n    <meta name=\"csrf-token\" content=\"",
		"    <meta name=\"gr:custom-html-analytics\" content=\"{&quot;seller_id&quot;:&quot;1790001&quot;,&quot;analytics&quot;:" +
			"{&quot;google_analytics_id&quot;:null,&quot;facebook_pixel_id&quot;:null,&quot;tiktok_pixel_id&quot;:null,&quot;free_sales&quot;:true}," +
			"&quot;tracking_enabled&quot;:true,&quot;has_product_third_party_analytics&quot;:false," +
			"&quot;third_party_analytics_domain&quot;:&quot;gumroad-analytics.com&quot;,&quot;permalink&quot;:&quot;gowebp1&quot;," +
			"&quot;name&quot;:&quot;Guide \\u003c1\\u003e&quot;}\">\n<script src=\"" + testAnalyticsScript + "\" crossorigin=\"\" type=\"module\"></script>\n" +
			"    <style>html,body{",
		"white-space:nowrap;border:0}html{background:#ABCDEF}</style>\n",
		"      <h1>Guide &lt;1&gt;</h1>\n      <p>Read https://example.com &amp; more</p>\n",
		"      src=\"/l/gowebp1/landing/embed\"\n      title=\"Guide &lt;1&gt;\"\n",
		"    <script nonce=\"NONCE\" data-cfasync=\"false\">\n",
		"      var BASE_CHECKOUT = \"/l/gowebp1?wanted=true\";\n",
		"      var STORE_HOSTNAMES = [\"gowebproductseller.gumroad.com\"];\n" +
			"      var GUMROAD_NAV_HOSTS = [\"gumroad.com\",\"app.gumroad.com\"];\n" +
			"              var GUMROAD_NAV_PATHS = [\"/library\",\"/checkout\"];\n",
		"    <script nonce=\"NONCE\" data-cfasync=\"false\" data-gumroad-background-wrapper>\n",
		"  })();\n</script>\n\n    \n    \n  </body>\n</html>\n",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("want %q", want)
		}
	}
	if strings.Contains(body, "<h1>x</h1>") || strings.Contains(body, "data-gumroad-waitlist-wrapper") {
		t.Error("the seller's HTML or a waitlist bridge is in the wrapper")
	}
	h := w.Header()
	for name, want := range map[string]string{
		"Content-Type": "text/html; charset=utf-8",
		"Link":         "<" + testAnalyticsScript + ">; rel=modulepreload; as=script; crossorigin=; nopush",
		"Vary":         "Origin",
	} {
		if got := h.Get(name); got != want {
			t.Errorf("%s %q, want %q", name, got, want)
		}
	}
	if csp := h.Get("Content-Security-Policy"); !strings.Contains(csp, "'nonce-NONCE'") {
		t.Errorf("CSP %q", csp)
	}
	// Not an inertia render, so no XSRF-TOKEN cookie.
	for _, c := range h.Values("Set-Cookie") {
		if strings.HasPrefix(c, "XSRF-TOKEN=") {
			t.Errorf("cookie %q", c)
		}
	}

	// A dry run renders the same document.
	dry := e.get(host, "/l/guide", e.dryRun(host, "/l/guide", testNow))
	if dry.Code != http.StatusOK || csrfMeta.ReplaceAllString(dry.Body.String(), "") != csrfMeta.ReplaceAllString(body, "") {
		t.Errorf("dry run: %d %q", dry.Code, dry.Header().Get("X-Go-Web-Fallback"))
	}
}

var csrfMeta = regexp.MustCompile(`"csrf-token" content="[^"]*"`)

// A signed-in visitor gets the document a signed-out one does; the seller and a collaborator
// get Rails' live reload.
func TestTheCustomHTMLWrapperSignedIn(t *testing.T) {
	const collabID = int64(1_790_002)
	e := newTestEnv(t)
	conn := testdb.Open(t)
	customHTML(t, e, conn)
	addBuyer(t, conn, nil)
	testdb.User(t, conn, collabID, map[string]any{"username": "collab_user", "external_id": "1790002", "name": "Collab"})
	testdb.Insert(t, conn, "affiliates", map[string]any{"id": int64(1_795_451), "type": "Collaborator", "seller_id": sellerID,
		"affiliate_user_id": collabID, "created_at": testNow, "updated_at": testNow})
	testdb.Insert(t, conn, "affiliates_links", map[string]any{"id": int64(1_795_452), "affiliate_id": int64(1_795_451),
		"link_id": productID, "created_at": testNow, "updated_at": testNow})

	out := e.get(host, "/l/guide", nil)
	in := e.get(host, "/l/guide", e.signedIn(buyerID, nil))
	if in.Code != http.StatusOK || e.railsHit != nil || csrfMeta.ReplaceAllString(in.Body.String(), "") != csrfMeta.ReplaceAllString(out.Body.String(), "") {
		t.Errorf("signed in: %d %q", in.Code, in.Header().Get("X-Go-Web-Fallback"))
	}
	// Only an accepted, alive collaborator previews.
	getsWrapper := func(who string) {
		w := e.get(host, "/l/guide", e.signedIn(collabID, nil))
		if w.Code != http.StatusOK || csrfMeta.ReplaceAllString(w.Body.String(), "") != csrfMeta.ReplaceAllString(out.Body.String(), "") {
			t.Errorf("%s: %d %q", who, w.Code, w.Header().Get("X-Go-Web-Fallback"))
		}
	}
	testdb.Insert(t, conn, "collaborator_invitations", map[string]any{"id": int64(1_795_453), "collaborator_id": int64(1_795_451),
		"created_at": testNow, "updated_at": testNow})
	getsWrapper("an invited collaborator")
	mustExec(t, conn, "DELETE FROM collaborator_invitations WHERE id = ?", 1_795_453)
	mustExec(t, conn, "UPDATE affiliates SET deleted_at = ? WHERE id = ?", testNow, 1_795_451)
	getsWrapper("a removed collaborator")
	mustExec(t, conn, "UPDATE affiliates SET deleted_at = NULL WHERE id = ?", 1_795_451)
	for i, user := range []int64{sellerID, collabID} {
		headers := e.signedIn(user, nil)
		// A signature is good for one request.
		headers["X-Go-Web-Dry-Run"] = e.dryRun(host, "/l/guide", testNow.Add(time.Duration(i)*time.Second))["X-Go-Web-Dry-Run"]
		if w := e.get(host, "/l/guide", headers); w.Code != http.StatusNoContent || w.Header().Get("X-Go-Web-Fallback") != "custom html preview" {
			t.Errorf("user %d: %d %q", user, w.Code, w.Header().Get("X-Go-Web-Fallback"))
		}
	}
}

func TestTheCustomHTMLWrapperShapes(t *testing.T) {
	domain := func(state string, issued any) func(t *testing.T, e *testEnv, conn *sql.DB) {
		return func(t *testing.T, e *testEnv, conn *sql.DB) {
			testdb.Insert(t, conn, "custom_domains", map[string]any{"id": int64(1_795_403), "user_id": sellerID, "domain": "example.com",
				"state": state, "ssl_certificate_issued_at": issued, "created_at": testNow, "updated_at": testNow})
		}
	}
	for _, c := range []struct {
		name, reason string
		setup        func(t *testing.T, e *testEnv, conn *sql.DB)
		wants, nots  []string
	}{
		// has_one takes either row, in no order.
		{name: "two custom domains", reason: "several custom domains", setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			domain("verified", testNow)(t, e, conn)
			testdb.Insert(t, conn, "custom_domains", map[string]any{"id": int64(1_795_406), "user_id": sellerID, "domain": "example.org",
				"state": "verified", "ssl_certificate_issued_at": testNow, "created_at": testNow, "updated_at": testNow})
		}},
		{name: "an active custom domain", setup: domain("verified", testNow.AddDate(0, 0, -89)),
			wants: []string{`var STORE_HOSTNAMES = ["gowebproductseller.gumroad.com","example.com"];`}},
		{name: "a custom domain whose certificate is due", setup: domain("verified", testNow.AddDate(0, 0, -90)),
			wants: []string{`var STORE_HOSTNAMES = ["gowebproductseller.gumroad.com"];`}},
		{name: "an unverified custom domain", setup: domain("unverified", testNow),
			wants: []string{`var STORE_HOSTNAMES = ["gowebproductseller.gumroad.com"];`}},
		// The thumbnail comes before the cover chain, and goes in as summary_large_image.
		{name: "a thumbnail", setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			testdb.Insert(t, conn, "thumbnails", map[string]any{"id": int64(1_795_404), "product_id": productID,
				"unsplash_url": "https://images.unsplash.com/a?b=1&c", "created_at": testNow, "updated_at": testNow})
		}, wants: []string{`<meta property="og:url" content="https://gowebproductseller.gumroad.com/l/guide">` + "\n" +
			`    <meta property="og:image" content="https://images.unsplash.com/a?b=1&amp;c">` + "\n" +
			`    <meta property="twitter:card" content="summary_large_image">` + "\n" +
			`    <meta property="twitter:image" content="https://images.unsplash.com/a?b=1&amp;c">` + "\n" +
			`    <script type="application/ld+json">`}},
		{name: "a seller's pixel", setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			conn.Exec("UPDATE users SET google_analytics_id = 'G-1' WHERE id = ?", sellerID)
		}, wants: []string{`    <meta property="gr:google_analytics:enabled" content="true">` + "\n" +
			`<meta property="gr:fb_pixel:enabled" content="true">` + "\n" +
			`<meta property="gr:tiktok_pixel:enabled" content="true">` + "\n\n" +
			`<meta name="gr:custom-html-analytics" content="{&quot;seller_id&quot;:&quot;1790001&quot;,&quot;analytics&quot;:{&quot;google_analytics_id&quot;:&quot;G-1&quot;,`}},
		// Third-party analytics off blanks the ids before they reach the page.
		{name: "analytics turned off", setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			conn.Exec("UPDATE users SET google_analytics_id = 'G-1', flags = flags | ? WHERE id = ?", userDisableThirdPartyAnalytics, sellerID)
		}, wants: []string{`    <meta name="gr:custom-html-analytics" content="{&quot;seller_id&quot;:&quot;1790001&quot;,&quot;analytics&quot;:` +
			`{&quot;google_analytics_id&quot;:null,&quot;facebook_pixel_id&quot;:null,&quot;tiktok_pixel_id&quot;:null,&quot;free_sales&quot;:true},` +
			`&quot;tracking_enabled&quot;:false,`}, nots: []string{"G-1", "gr:google_analytics:enabled"}},
		{name: "a background color the CSS check refuses", setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			testdb.Insert(t, conn, "seller_profiles", map[string]any{"id": int64(1_795_405), "seller_id": sellerID,
				"background_color": "#fff;}x{", "created_at": testNow, "updated_at": testNow})
		}, wants: []string{"white-space:nowrap;border:0}</style>\n"}},
		// User#seller_profile builds one, whose after_initialize sets the default color.
		{name: "no seller profile", setup: func(t *testing.T, e *testEnv, conn *sql.DB) {},
			wants: []string{"white-space:nowrap;border:0}html{background:#ffffff}</style>\n"}},
		{name: "a blank description", setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			conn.Exec("UPDATE links SET description = '<p> </p>' WHERE id = ?", productID)
		}, wants: []string{`<meta name="description" content="Available on Gumroad">`, "      <p>Available on Gumroad</p>\n"}},
		// The wrapper has no set_product_page_meta, so no calendar preload.
		{name: "a call", setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			conn.Exec("UPDATE links SET native_type = 'call' WHERE id = ?", productID)
		}, wants: []string{`<script type="application/ld+json">`}, nots: []string{"call-calendar", "Calendar"}},
		{name: "a commission", setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			conn.Exec("UPDATE links SET native_type = 'commission' WHERE id = ?", productID)
		}, wants: []string{`<script type="application/ld+json">`}},
		// A draft taking waitlist signups gets the bridge, with ids from this render only.
		{name: "a draft taking waitlist signups", setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			conn.Exec("UPDATE links SET draft = 1, flags = flags | ? WHERE id = ?", productWaitlistEnabled, productID)
		}, wants: []string{"  })();\n</script>\n\n    <script nonce=\"NONCE\" data-cfasync=\"false\" data-gumroad-waitlist-wrapper>\n" +
			"  (function () {\n    var frame = document.getElementById(\"gumroad-landing-frame\");\n" +
			"    var SELLER_ID = \"1790001\";\n    var PRODUCT_ID = \"%[1]s\";\n    var ENDPOINT = \"/follow_from_embed_form\";\n",
			"  })();\n</script>\n\n    \n  </body>\n</html>\n"}},
	} {
		t.Run(c.name, func(t *testing.T) {
			e := newTestEnv(t)
			conn := testdb.Open(t)
			customHTML(t, e, conn)
			if c.reason != "" {
				c.setup(t, e, conn)
				e.render(t, nil, c.reason)
				return
			}
			c.setup(t, e, conn)
			w := e.get(host, "/l/guide", nil)
			if w.Code != http.StatusOK || e.railsHit != nil {
				t.Fatalf("%d %q, Rails hit: %v", w.Code, w.Header().Get("X-Go-Web-Fallback"), e.railsHit != nil)
			}
			e.wantAll(t, w.Body.String(), c.wants, productID)
			for _, not := range c.nots {
				if strings.Contains(w.Body.String(), not) {
					t.Errorf("unwanted %q", not)
				}
			}
		})
	}
}
