package products

import (
	"database/sql"
	"net/http"
	"regexp"
	"slices"
	"strings"
	"testing"

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

	// Discover's search box asking for suggestions gets the document a visit does.
	target := "/l/guide?layout=discover&query=pen"
	plain := e.get(host, target, nil)
	partial := e.get(host, target, map[string]string{"X-Inertia": "true", "X-Requested-With": "XMLHttpRequest",
		"X-Inertia-Partial-Component": "Products/Discover/Show", "X-Inertia-Partial-Data": "autocomplete_results"})
	if partial.Code != http.StatusOK || e.railsHit != nil ||
		csrfMeta.ReplaceAllString(partial.Body.String(), "") != csrfMeta.ReplaceAllString(plain.Body.String(), "") {
		t.Fatalf("partial reload: %d %q", partial.Code, partial.Header().Get("X-Go-Web-Fallback"))
	}
	for _, name := range []string{"Content-Type", "Link", "Vary", "X-Robots-Tag"} {
		if got, want := partial.Header().Get(name), plain.Header().Get(name); got != want {
			t.Errorf("partial reload %s %q, want %q", name, got, want)
		}
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
	// The seller and a collaborator preview it: the same page, with the live reload last.
	script := strings.NewReplacer("«nonce»", "NONCE", "«version_src»", `"/l/gowebp1/landing/version"`,
		"«poll_interval_ms»", "2000").Replace(customHTMLLiveReload)
	preview := strings.Replace(csrfMeta.ReplaceAllString(out.Body.String(), ""), "    \n  </body>", "    "+script+"\n  </body>", 1)
	for _, want := range []string{`var versionUrl = "/l/gowebp1/landing/version";`, "setInterval(poll, 2000);"} {
		if !strings.Contains(preview, want) {
			t.Fatalf("no %s", want)
		}
	}
	for _, user := range []int64{sellerID, collabID} {
		w := e.get(host, "/l/guide", e.signedIn(user, nil))
		if w.Code != http.StatusOK || e.railsHit != nil || csrfMeta.ReplaceAllString(w.Body.String(), "") != preview {
			t.Errorf("user %d: %d %q", user, w.Code, w.Header().Get("X-Go-Web-Fallback"))
		}
	}
	// Unpublished, it's still the collaborator's preview, which other visitors don't get.
	mustExec(t, conn, "UPDATE links SET purchase_disabled_at = ? WHERE id = ?", testNow, productID)
	if w := e.get(host, "/l/guide", e.signedIn(collabID, nil)); w.Code != http.StatusOK || !strings.Contains(w.Body.String(), script) {
		t.Errorf("unpublished: %d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
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
		// The has_one's unordered statement takes the row MySQL's plan returns, here the lower id's.
		{name: "two custom domains", wants: []string{`var STORE_HOSTNAMES = ["gowebproductseller.gumroad.com","example.com"];`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
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

// The wrapper reads one cover's URL, social_share_image's of the main cover, so only that one
// queues its retina variant and caches its URL.
func TestTheCustomHTMLWrapperReadsTheMainCoverAlone(t *testing.T) {
	second := func(t *testing.T, conn *sql.DB) {
		testdb.Insert(t, conn, "asset_previews", map[string]any{"id": int64(1_790_402), "link_id": productID, "guid": "second-guid",
			"position": 1, "created_at": testNow, "updated_at": testNow})
		addBlob(t, conn, 1_790_503, "covers/second", "b.jpg", "image/jpeg", `{"identified":true,"width":2000,"height":1000,"analyzed":true}`)
		addAttachment(t, conn, 1_790_603, "file", "AssetPreview", 1_790_402, 1_790_503)
	}
	for _, c := range []struct {
		name          string
		mainProcessed bool
		queued        string
		cached        []string
	}{
		{name: "a processed main cover", mainProcessed: true, cached: []string{"attachment_1790601_retina_url"}},
		{name: "an unprocessed main cover", queued: `"args":[1790401],"class":"ProcessAssetPreviewRetinaWorker"`,
			cached: []string{"attachment_1790601_original_url"}},
	} {
		t.Run(c.name, func(t *testing.T) {
			e := newTestEnv(t)
			jobs := sidekiqJobs(t, e)
			conn := testdb.Open(t)
			customHTML(t, e, conn)
			addCover(t, c.mainProcessed)
			second(t, conn)
			w := e.get(host, "/l/guide", nil)
			if w.Code != http.StatusOK || e.railsHit != nil {
				t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
			}
			queued, _ := jobs.List("queue:low")
			if c.queued == "" && len(queued) != 0 || c.queued != "" && (len(queued) != 1 || !strings.Contains(queued[0], c.queued)) {
				t.Errorf("queue:low %v", queued)
			}
			var covers []string
			for _, key := range e.cache.writes {
				if strings.HasPrefix(key, "attachment_") {
					covers = append(covers, key)
				}
			}
			if !slices.Equal(covers, c.cached) {
				t.Errorf("cover cache writes %v, want %v", covers, c.cached)
			}
		})
	}
}

// render_custom_html_if_present runs before show's /coffee redirect, and its wrapper is any
// product's.
func TestACoffeeProductsCustomHTML(t *testing.T) {
	e := newTestEnv(t)
	conn := testdb.Open(t)
	// initialize_suggested_amount_if_needed!'s shape: a $0 base, pay what you want, and the
	// suggested amount as a nameless option, which the JSON-LD offer's price adds.
	mustExec(t, conn, "UPDATE links SET native_type = 'coffee', price_cents = 0, customizable_price = 1 WHERE id = ?", productID)
	mustExec(t, conn, "UPDATE prices SET price_cents = 0 WHERE id = ?", priceID)
	testdb.Insert(t, conn, "variant_categories", map[string]any{"id": int64(1_799_931), "link_id": productID, "title": "Suggested Amounts"})
	testdb.Insert(t, conn, "base_variants", map[string]any{"id": int64(1_799_932), "type": "Variant", "variant_category_id": int64(1_799_931),
		"name": "", "price_difference_cents": 300, "created_at": testNow, "updated_at": testNow})
	customHTML(t, e, conn)
	w := e.get(host, "/l/guide", nil)
	if w.Code != http.StatusOK || e.railsHit != nil {
		t.Fatalf("%d %q, Rails hit: %v", w.Code, w.Header().Get("X-Go-Web-Fallback"), e.railsHit != nil)
	}
	e.wantAll(t, w.Body.String(), []string{
		`<link rel="canonical" href="https://gowebproductseller.gumroad.com/l/guide">`,
		`"/l/gowebp1?wanted=true"`,
		`"url":"https://gowebproductseller.gumroad.com/l/guide","price":3.0}`,
		`"@type":"Product","name":"Guide \u003c1\u003e"`,
	})
}

// Pages::WaitlistForm.found_in? reads the message anywhere, and the form only as Loofah parses it.
func TestWaitlistFormFound(t *testing.T) {
	for html, want := range map[string]bool{
		`<form data-gumroad-waitlist><input name="email"></form>`:                             true,
		`<p>Join</p><div><FORM DATA-GUMROAD-WAITLIST="1"></FORM></div>`:                       true,
		`<button onclick="parent.postMessage({type: 'gumroad:waitlist'}, '*')">Join</button>`: true,
		`<form data-waitlist></form>`:                                                         false,
		`<div data-gumroad-waitlist></div>`:                                                   false,
		`<!-- <form data-gumroad-waitlist> -->`:                                               false,
		`<script>var form = "<form data-gumroad-waitlist>";</script>`:                         false,
	} {
		if got, err := waitlistFormFound(html); err != nil || got != want {
			t.Errorf("%s: %v %v", html, got, err)
		}
	}
}

// The wrapper's checkout carries params[:offer_code].presence || params[:code].presence, and a
// code noindexes it.
func TestTheCustomHTMLWrappersCheckoutCode(t *testing.T) {
	e := newTestEnv(t)
	customHTML(t, e, testdb.Open(t))
	for target, want := range map[string]string{
		"/l/guide":                            `"/l/gowebp1?wanted=true"`,
		"/l/guide/SAVE10":                     `"/l/gowebp1?wanted=true\u0026code=SAVE10"`,
		"/l/guide?offer_code=&code=SAVE10":    `"/l/gowebp1?wanted=true\u0026code=SAVE10"`,
		"/l/guide?offer_code=OFF&code=SAVE10": `"/l/gowebp1?wanted=true\u0026code=OFF"`,
	} {
		w := e.get(host, target, nil)
		if w.Code != http.StatusOK || e.railsHit != nil || !strings.Contains(w.Body.String(), "var BASE_CHECKOUT = "+want+";") {
			t.Errorf("%s: %d %q, want %s", target, w.Code, w.Header().Get("X-Go-Web-Fallback"), want)
		}
		// set_x_robots_tag_header reads params[:code] alone.
		if noindex := w.Header().Get("X-Robots-Tag") == "noindex"; noindex != strings.Contains(target, "SAVE10") {
			t.Errorf("%s: X-Robots-Tag %q", target, w.Header().Get("X-Robots-Tag"))
		}
	}
}
