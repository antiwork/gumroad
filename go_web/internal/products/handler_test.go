package products

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"html"
	"io"
	"log/slog"
	"maps"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"

	"github.com/antiwork/gumroad/go_web/internal/customstyles"
	"github.com/antiwork/gumroad/go_web/internal/flipper"
	"github.com/antiwork/gumroad/go_web/internal/inertia"
	"github.com/antiwork/gumroad/go_web/internal/obfuscate"
	"github.com/antiwork/gumroad/go_web/internal/pages"
	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/session"
	"github.com/antiwork/gumroad/go_web/internal/session/testdb"
	"github.com/antiwork/gumroad/go_web/internal/storage"
	"github.com/antiwork/gumroad/go_web/internal/vite"
	"github.com/antiwork/gumroad/go_web/internal/web"
)

const (
	testSecretKeyBase = "go-web-products-test-secret-key-base"
	sellerID          = int64(1_790_001)
	productID         = int64(1_790_101)
	priceID           = int64(1_790_201)
	host              = "gowebproductseller.gumroad.com"
)

var testNow = time.Date(2026, 11, 6, 12, 0, 0, 0, time.UTC)

type presentFiles struct{}

func (presentFiles) Exists(context.Context, string) (bool, error) { return true, nil }

// fakeCache is Rails.cache in memory.
type fakeCache struct {
	mu     sync.Mutex
	values map[string]any
	writes []string
}

func (c *fakeCache) Read(_ context.Context, key string) (any, bool, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	v, ok := c.values[key]
	return v, ok, nil
}

func (c *fakeCache) Write(_ context.Context, key string, value any, _ time.Duration) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.values[key] = value
	c.writes = append(c.writes, key)
	return nil
}

type testEnv struct {
	t        *testing.T
	handler  http.Handler
	ids      *obfuscate.IDs
	cache    *fakeCache
	redis    *miniredis.Miniredis
	railsHit *http.Request
}

func newTestEnv(t *testing.T) *testEnv {
	t.Helper()
	conn := testdb.Open(t)
	e := &testEnv{t: t, cache: &fakeCache{values: map[string]any{}}}
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		e.railsHit = r
		io.WriteString(w, "rails")
	}))
	t.Cleanup(upstream.Close)
	upstreams := filepath.Join(t.TempDir(), "upstreams")
	if err := os.WriteFile(upstreams, []byte(strings.TrimPrefix(upstream.URL, "http://")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	env, err := web.LoadEnvironment(func(k string) string {
		return map[string]string{"RAILS_ENV": "production", "REVISION": "test"}[k]
	})
	if err != nil {
		t.Fatal(err)
	}
	codec, _ := session.NewCodec(testSecretKeyBase)
	e.ids, _ = obfuscate.New("go-web-products-cipher-key", "123456789")
	e.redis = miniredis.RunT(t)
	redisClient := redis.NewClient(&redis.Options{Addr: e.redis.Addr()})
	manifest, err := vite.LoadDir(env.AssetHost(), "../vite/testdata")
	if err != nil {
		t.Fatal(err)
	}
	layout, err := inertia.NewLayout(inertia.LayoutConfig{OGNamespace: "gumroad", DNSPrefetch: []string{env.AssetHost()},
		ActionCableURL: "wss://cable.gumroad.com/cable", Manifest: manifest})
	if err != nil {
		t.Fatal(err)
	}
	csp, err := web.NewCSP(env, func(_, f string) string { return f })
	if err != nil {
		t.Fatal(err)
	}
	flags := map[string]*flipper.Flag{}
	app := web.NewApp(env, slog.New(slog.NewTextHandler(testLog(), nil)), redisClient)
	Register(app, &Config{
		Env:      env,
		DB:       conn,
		Stack:    rails.NewStack(env, ""),
		Store:    session.NewStore(codec, "production", "https", "", false),
		Resolver: &session.Resolver{Users: &session.Users{DB: conn}, Redis: redisClient, Codec: codec},
		IDs:      e.ids,
		Proxy:    web.NewRailsProxy(upstreams),
		Meta:     inertia.DefaultMeta{Title: "Gumroad", Environment: "production", AssetHost: env.AssetHost(), AnalyticsByEnvironment: true},
		Now:      func() time.Time { return testNow },
		Page: &PageConfig{
			Layout:  layout,
			CSP:     csp,
			Shared:  pages.NewShared(env, func(context.Context) (bool, error) { return true, nil }),
			Avatars: &storage.Avatars{DB: conn, Exists: presentFiles{}, AssetHost: env.AssetHost(), Now: func() time.Time { return testNow }},
			Cache:   e.cache,
			Redis:   redisClient,
			Flag: func(name string) *flipper.Flag {
				if flags[name] == nil {
					flags[name] = flipper.New(redisClient, name)
				}
				return flags[name]
			},
			CDNMap: [][2]string{{"https://s3.amazonaws.com/gumroad/", "https://static-2.gumroad.com/res/gumroad/"},
				{"https://gumroad-public-storage.s3.amazonaws.com/", "https://public-files.gumroad.com/"}},
			PublicStorageURL: "https://gumroad-public-storage.s3.amazonaws.com/",
			OGNamespace:      "gumroad",
			NewNonce:         func() string { return "NONCE" },
		},
		DryRunKey:  pages.DryRunKey(testSecretKeyBase),
		DryRunOnce: redisClient,
	})
	e.handler = app

	testdb.User(t, conn, sellerID, map[string]any{"username": "gowebproductseller", "external_id": "1790001", "name": "Seller",
		"user_risk_state": "compliant"})
	testdb.Insert(t, conn, "links", map[string]any{"id": productID, "user_id": sellerID, "name": "Guide <1>", "unique_permalink": "gowebp1",
		"custom_permalink": "guide", "description": `<p>Read https://example.com &amp; more</p>`, "price_cents": 500,
		"json_data": `{"custom_summary":"A short guide"}`, "created_at": testNow, "updated_at": testNow})
	testdb.Insert(t, conn, "prices", map[string]any{"id": priceID, "link_id": productID, "price_cents": 500, "currency": "usd",
		"created_at": testNow, "updated_at": testNow})
	return e
}

func (e *testEnv) get(hostname, target string, headers map[string]string) *httptest.ResponseRecorder {
	e.t.Helper()
	e.railsHit = nil
	r := httptest.NewRequest("GET", target, nil)
	r.Host = hostname
	r.RemoteAddr = "10.1.0.9:5000"
	r.Header.Set("X-Forwarded-Proto", "https")
	r.Header.Set("X-Forwarded-For", "203.0.113.9")
	r.Header.Set("Accept", "text/html")
	r.Header.Set("User-Agent", "Mozilla/5.0 (Macintosh)")
	for k, v := range headers {
		r.Header.Set(k, v)
	}
	w := httptest.NewRecorder()
	e.handler.ServeHTTP(w, r)
	return w
}

func (e *testEnv) dryRun(hostname, target string, at time.Time) map[string]string {
	return map[string]string{"X-Go-Web-Dry-Run": pages.SignDryRun(pages.DryRunKey(testSecretKeyBase), "GET", hostname, target, at)}
}

var dataPage = regexp.MustCompile(`data-page="([^"]*)"`)

func pageProps(t *testing.T, body string) map[string]any {
	t.Helper()
	m := dataPage.FindStringSubmatch(body)
	if m == nil {
		t.Fatalf("no data-page in\n%s", body)
	}
	var page struct {
		Component string         `json:"component"`
		Props     map[string]any `json:"props"`
	}
	if err := json.Unmarshal([]byte(html.UnescapeString(m[1])), &page); err != nil {
		t.Fatal(err)
	}
	if page.Component != component {
		t.Fatalf("component %q", page.Component)
	}
	return page.Props
}

func TestASignedOutVisitorGetsTheProductPage(t *testing.T) {
	e := newTestEnv(t)
	w := e.get(host, "/l/guide", nil)
	if w.Code != http.StatusOK {
		t.Fatalf("status %d, rails %v", w.Code, e.railsHit != nil)
	}
	body := w.Body.String()
	props := pageProps(t, body)
	product := props["product"].(map[string]any)
	for key, want := range map[string]any{
		"id": e.ids.Encrypt(productID), "permalink": "gowebp1", "name": "Guide <1>", "price_cents": 500.0, "currency_code": "usd",
		"long_url": "https://gowebproductseller.gumroad.com/l/guide", "summary": "A short guide", "is_published": true,
		"description_html": `<p>Read <a href="https://example.com" target="_blank" rel="noopener noreferrer nofollow">https://example.com</a> &amp; more</p>`,
	} {
		if product[key] != want {
			t.Errorf("product.%s = %#v, want %#v", key, product[key], want)
		}
	}
	seller := product["seller"].(map[string]any)
	if seller["profile_url"] != "https://"+host+"/" || seller["name"] != "Seller" {
		t.Errorf("seller %v", seller)
	}
	if props["selection_discounts"] == nil || props["wishlists"] == nil || props["creator_profile"] == nil {
		t.Errorf("props %v", props)
	}
	for _, want := range []string{
		`<title inertia="title">Guide &lt;1&gt;</title>`,
		`<meta name="description" content="Read https://example.com &amp; more" inertia="meta-name-description">`,
		`<meta property="product:price:amount" content="5.0" inertia="meta-property-product-price-amount">`,
		`<link rel="canonical" href="https://gowebproductseller.gumroad.com/l/guide" inertia="canonical">`,
		`<script type="application/ld+json" inertia="structured-data">{"@context":"https://schema.org","@type":"Product","name":"Guide \u003c1\u003e","description":"A short guide"`,
		`<style inertia="custom_styles">` + defaultStyles(t) + `</style>`,
		`<body id="product_page" class="group/body mac" style="">`,
	} {
		if !strings.Contains(body, want) {
			t.Errorf("missing %s", want)
		}
	}
	if csp := w.Header().Get("Content-Security-Policy"); !strings.Contains(csp, "'nonce-NONCE'") {
		t.Errorf("CSP %q", csp)
	}
	cookies := w.Header().Values("Set-Cookie")
	if len(cookies) != 3 || !strings.HasPrefix(cookies[0], "_gumroad_guid=") || !strings.HasPrefix(cookies[1], "XSRF-TOKEN=") ||
		!strings.HasPrefix(cookies[2], "_gumroad_app_session=") {
		t.Errorf("cookies %v", cookies)
	}
	if w.Header().Get("X-Robots-Tag") != "" || w.Header().Get("Strict-Transport-Security") != "" {
		t.Errorf("headers %v", w.Header())
	}
}

// addCover gives the product an uploaded 2000×1000 JPEG cover, with its retina variant
// processed when variant is true.
func addCover(t *testing.T, variant bool) {
	conn := testdb.Open(t)
	testdb.Insert(t, conn, "asset_previews", map[string]any{"id": int64(1_790_401), "link_id": productID, "guid": "cover-guid",
		"position": 0, "created_at": testNow, "updated_at": testNow})
	testdb.Insert(t, conn, "active_storage_blobs", map[string]any{"id": int64(1_790_501), "key": "covers/original", "filename": "a.jpg",
		"content_type": "image/jpeg", "metadata": `{"identified":true,"width":2000,"height":1000,"analyzed":true}`,
		"service_name": "amazon_public", "byte_size": 1, "created_at": testNow})
	testdb.Insert(t, conn, "active_storage_attachments", map[string]any{"id": int64(1_790_601), "name": "file",
		"record_type": "AssetPreview", "record_id": int64(1_790_401), "blob_id": int64(1_790_501), "created_at": testNow})
	if !variant {
		return
	}
	// Ruby's digest of {format: "jpg", resize_to_limit: [1005, nil]}.
	testdb.Insert(t, conn, "active_storage_variant_records", map[string]any{"id": int64(1_790_701), "blob_id": int64(1_790_501),
		"variation_digest": "WX6OQ3hf/g9WoAI2n/sUdFF1vxA="})
	testdb.Insert(t, conn, "active_storage_blobs", map[string]any{"id": int64(1_790_502), "key": "covers/retina", "filename": "a.jpg",
		"content_type": "image/jpeg", "service_name": "amazon_public", "byte_size": 1, "created_at": testNow})
	testdb.Insert(t, conn, "active_storage_attachments", map[string]any{"id": int64(1_790_602), "name": "image",
		"record_type": "ActiveStorage::VariantRecord", "record_id": int64(1_790_701), "blob_id": int64(1_790_502), "created_at": testNow})
}

func TestAnUploadedCoverRendersItsRetinaVariant(t *testing.T) {
	e := newTestEnv(t)
	addCover(t, true)
	w := e.get(host, "/l/guide", nil)
	if w.Code != http.StatusOK {
		t.Fatalf("status %d, fallback %q, rails %v", w.Code, w.Header().Get("X-Go-Web-Fallback"), e.railsHit != nil)
	}
	body := w.Body.String()
	product := pageProps(t, body)["product"].(map[string]any)
	covers := product["covers"].([]any)
	if len(covers) != 1 || product["main_cover_id"] != "cover-guid" {
		t.Fatalf("covers %v, main %v", covers, product["main_cover_id"])
	}
	retina, original := "https://public-files.gumroad.com/covers/retina", "https://public-files.gumroad.com/covers/original"
	for key, want := range map[string]any{"url": retina, "original_url": original, "id": "cover-guid", "type": "image",
		"filetype": "jpg", "width": 670.0, "height": 335.0, "native_width": 2000.0, "native_height": 1000.0, "thumbnail": nil} {
		if got := covers[0].(map[string]any)[key]; got != want {
			t.Errorf("cover %s = %#v, want %#v", key, got, want)
		}
	}
	for _, want := range []string{
		`<meta property="og:image" content="` + retina + `"`,
		`<meta property="twitter:card" content="summary_large_image"`,
		`<link rel="preload" as="image" href="` + retina + `"`,
	} {
		if !strings.Contains(body, want) {
			t.Errorf("missing %s", want)
		}
	}
	// Rails.cache.fetch writes both URLs once the page renders.
	if !slices.Contains(e.cache.writes, "attachment_1790601_original_url") || !slices.Contains(e.cache.writes, "attachment_1790601_retina_url") {
		t.Errorf("cache writes %v", e.cache.writes)
	}
}

func TestACoverWithoutItsRetinaVariantGoesToRails(t *testing.T) {
	e := newTestEnv(t)
	addCover(t, false)
	if w := e.get(host, "/l/guide", e.dryRun(host, "/l/guide", testNow)); w.Header().Get("X-Go-Web-Fallback") != "retina variant unprocessed" {
		t.Errorf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
}

func TestAnotherSpellingOfThePermalinkRedirectsPermanently(t *testing.T) {
	e := newTestEnv(t)
	w := e.get(host, "/l/gowebp1?a%20b=1", nil)
	if w.Code != http.StatusMovedPermanently || w.Header().Get("Location") != "https://"+host+"/l/guide?a%20b=1" {
		t.Errorf("%d %q", w.Code, w.Header().Get("Location"))
	}
}

func TestABannedOrMissingProductIsNotFound(t *testing.T) {
	e := newTestEnv(t)
	if w := e.get(host, "/l/nope", nil); w.Code != http.StatusNotFound || len(w.Header().Values("Set-Cookie")) != 0 {
		t.Errorf("missing: %d %v", w.Code, w.Header())
	}
	conn := testdb.Open(t)
	conn.Exec("UPDATE links SET banned_at = ? WHERE id = ?", testNow, productID)
	if w := e.get(host, "/l/guide", nil); w.Code != http.StatusNotFound {
		t.Errorf("banned: %d", w.Code)
	}
}

func TestWhatThisPortLeavesToRailsGoesThere(t *testing.T) {
	e := newTestEnv(t)
	conn := testdb.Open(t)
	at := testNow
	cases := []struct {
		name, host, target, reason string
		headers                    map[string]string
		setup, undo                func()
	}{
		{name: "app domain", host: "gumroad.com", target: "/l/guide", reason: "host"},
		{name: "offer code path", host: host, target: "/l/guide/CODE", reason: "offer code path"},
		{name: "a code param", host: host, target: "/l/guide?code=X", reason: "param code"},
		{name: "a utm visit", host: host, target: "/l/guide?utm_source=a&utm_medium=b&utm_campaign=c", reason: "utm link"},
		{name: "a seller without a user", host: "nosuchseller.gumroad.com", target: "/l/guide", reason: "no seller"},
		{name: "the analytics host's route", host: "gumroad-analytics-com.gumroad.com", target: "/l/guide", reason: "host"},
		{name: "a Forwarded header", host: host, target: "/l/guide", reason: "forwarded header",
			headers: map[string]string{"Forwarded": "host=other.gumroad.com"}},
		{name: "a forwarded port", host: host, target: "/l/guide", reason: "port", headers: map[string]string{"X-Forwarded-Port": "8443"}},
		{name: "storefront", host: host, target: "/l/guide", reason: "storefront",
			setup: func() {
				conn.Exec("UPDATE users SET flags = flags | ? WHERE id = ?", userProductPageStorefrontEnabled, sellerID)
			},
			undo: func() {
				conn.Exec("UPDATE users SET flags = flags & ~? WHERE id = ?", userProductPageStorefrontEnabled, sellerID)
			}},
		{name: "membership", host: host, target: "/l/guide", reason: "membership",
			setup: func() {
				conn.Exec("UPDATE links SET flags = flags | ? WHERE id = ?", productIsTieredMembership, productID)
			},
			undo: func() {
				conn.Exec("UPDATE links SET flags = flags & ~? WHERE id = ?", productIsTieredMembership, productID)
			}},
		{name: "the seller's refund policy", host: host, target: "/l/guide", reason: "seller refund policy",
			setup: func() {
				conn.Exec("UPDATE users SET flags = flags | ? WHERE id = ?", userRefundPolicyEnabled, sellerID)
			},
			undo: func() {
				conn.Exec("UPDATE users SET flags = flags & ~? WHERE id = ?", userRefundPolicyEnabled, sellerID)
			}},
		{name: "custom html", host: host, target: "/l/guide", reason: "custom html",
			setup: func() {
				e.redis.HSet("custom_html_pages", "boolean", "true")
				testdb.Insert(t, conn, "pages", map[string]any{"id": int64(1_790_301), "pageable_type": "Link", "pageable_id": productID,
					"custom_html": "<h1>x</h1>", "created_at": testNow, "updated_at": testNow})
			},
			undo: func() { conn.Exec("DELETE FROM pages WHERE id = ?", 1_790_301) }},
	}
	for i, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if c.setup != nil {
				c.setup()
				defer c.undo()
			}
			headers := e.dryRun(c.host, c.target, at.Add(-time.Duration(i)*time.Second))
			maps.Copy(headers, c.headers)
			w := e.get(c.host, c.target, headers)
			if w.Code != http.StatusNoContent || w.Header().Get("X-Go-Web-Fallback") != c.reason || e.railsHit != nil {
				t.Errorf("%d %q rails %v", w.Code, w.Header().Get("X-Go-Web-Fallback"), e.railsHit != nil)
			}
			// Without a dry run, Rails answers.
			if e.get(c.host, c.target, c.headers); e.railsHit == nil {
				t.Error("not handed to Rails")
			}
		})
	}
}

func TestAProductRefundPolicyRendersHere(t *testing.T) {
	policy := func(period any, finePrint string) map[string]any {
		return map[string]any{"id": int64(1_790_801), "seller_id": sellerID, "product_id": productID, "max_refund_period_in_days": period,
			"fine_print": finePrint, "created_at": testNow, "updated_at": testNow}
	}
	for _, c := range []struct {
		name string
		flag bool
		row  map[string]any
		want string
	}{
		{"fine print", true, policy(14, "Within 14 days &amp; unused.\nEmail us.\n\nThanks"),
			`{"title":"14-day money back guarantee","fine_print":"\u003cp\u003eWithin 14 days \u0026amp; unused.\n\u003cbr /\u003eEmail us.\u003c/p\u003e\n\n\u003cp\u003eThanks\u003c/p\u003e","updated_at":"2026-11-06"}`},
		{"blank fine print, unknown period", true, policy(45, " "), `{"title":null,"fine_print":null,"updated_at":"2026-11-06"}`},
		{"no period", true, policy(nil, ""), `{"title":null,"fine_print":null,"updated_at":"2026-11-06"}`},
		{"flag without a row", true, nil, `null`},
		{"row without the flag", false, policy(30, "x"), `null`},
	} {
		t.Run(c.name, func(t *testing.T) {
			e := newTestEnv(t)
			conn := testdb.Open(t)
			if c.flag {
				conn.Exec("UPDATE links SET flags = flags | ? WHERE id = ?", productRefundPolicyEnabled, productID)
			}
			if c.row != nil {
				testdb.Insert(t, conn, "refund_policies", c.row)
			}
			w := e.get(host, "/l/guide", nil)
			if w.Code != http.StatusOK || e.railsHit != nil {
				t.Fatalf("%d, Rails hit: %v", w.Code, e.railsHit != nil)
			}
			page := html.UnescapeString(dataPage.FindStringSubmatch(w.Body.String())[1])
			if !strings.Contains(page, `"refund_policy":`+c.want+`,`) {
				t.Errorf("want refund_policy %s in %s", c.want, page[strings.Index(page, `"refund_policy"`):][:200])
			}
		})
	}
}

// The JSON-LD offer converts a non-USD price through the cached rate, else keeps its currency.
// The fixture's price is 500: euro cents, or whole yen.
func TestANonUSDProductOffersItsPriceInUSD(t *testing.T) {
	const url = `"availability":"https://schema.org/InStock","url":"https://gowebproductseller.gumroad.com/l/guide",`
	for _, c := range []struct{ code, rate, want string }{
		{"eur", "0.92", `"priceCurrency":"USD",` + url + `"price":5.43}`},
		{"eur", "", `"priceCurrency":"EUR",` + url + `"price":5.0}`},
		{"eur", "0", `"priceCurrency":"EUR",` + url + `"price":5.0}`},
		{"jpy", "151.23", `"priceCurrency":"USD",` + url + `"price":3.31}`},
		{"jpy", "", `"priceCurrency":"JPY",` + url + `"price":500.0}`},
	} {
		t.Run(c.code+" at "+c.rate, func(t *testing.T) {
			e := newTestEnv(t)
			conn := testdb.Open(t)
			conn.Exec("UPDATE links SET price_currency_type = ? WHERE id = ?", c.code, productID)
			conn.Exec("UPDATE prices SET currency = ? WHERE id = ?", c.code, priceID)
			if c.rate != "" {
				e.redis.Set("currencies:"+strings.ToUpper(c.code), c.rate)
			}
			w := e.get(host, "/l/guide", nil)
			if w.Code != http.StatusOK || e.railsHit != nil {
				t.Fatalf("%d, Rails hit: %v", w.Code, e.railsHit != nil)
			}
			if !strings.Contains(w.Body.String(), c.want) {
				t.Errorf("no %s in the JSON-LD", c.want)
			}
		})
	}
}

// buyer_currency_display and buyer_local_price_props for a visitor whose currency cookie
// differs from the product's, at the cached rates.
func TestABuyerSeesTheLocalPrice(t *testing.T) {
	display := func(shown, product, local, rate, mode string) string {
		return `"buyer_currency_display":{"product_id":"%s","buyer_currency_shown":"` + shown + `","product_currency":"` + product +
			`","buyer_local_price_cents":` + local + `,"rate":` + rate + `,"display_mode":"` + mode + `"}`
	}
	eurLocal := display("eur", "usd", "462", "0.92345", "buyer_local") + `,"buyer_currency":"eur","buyer_local_currency_rate":0.92345,` +
		`"buyer_local_currency_subunit_to_unit":100,"buyer_local_price_cents":462,"rental_price_cents":`
	usdDefault := display("usd", "usd", "null", "null", "default") + `,"rental_price_cents":`
	platform := func(t *testing.T, conn *sql.DB, currency, jsonData string) {
		testdb.Insert(t, conn, "merchant_accounts", map[string]any{"id": int64(1_790_901), "charge_processor_id": "stripe",
			"currency": currency, "json_data": jsonData, "created_at": testNow, "updated_at": testNow})
	}
	own := func(t *testing.T, conn *sql.DB, country, jsonData string) {
		testdb.Insert(t, conn, "merchant_accounts", map[string]any{"id": int64(1_790_902), "user_id": sellerID, "charge_processor_id": "stripe",
			"country": country, "currency": "usd", "json_data": jsonData, "charge_processor_alive_at": testNow, "created_at": testNow,
			"updated_at": testNow})
	}
	charging := func(e *testEnv) { e.redis.HSet("buyer_currency_charging", "boolean", "true") }
	for _, c := range []struct {
		name, product, cookie, want, reason string
		setup                               func(t *testing.T, e *testEnv, conn *sql.DB)
	}{
		{"charging off", "usd", "EUR", eurLocal, "", nil},
		{"charging on, platform settles in USD", "usd", "EUR", eurLocal, "", func(t *testing.T, e *testEnv, conn *sql.DB) {
			charging(e)
			platform(t, conn, "usd", `{}`)
		}},
		{"an old mismatch marker", "usd", "EUR", eurLocal, "", func(t *testing.T, e *testEnv, conn *sql.DB) {
			charging(e)
			platform(t, conn, "usd", `{"settlement_currency_mismatch_map":{"eur":"2026-11-04T12:00:00Z"}}`)
		}},
		{"a fresh mismatch marker", "usd", "EUR", usdDefault, "", func(t *testing.T, e *testEnv, conn *sql.DB) {
			charging(e)
			platform(t, conn, "usd", `{"settlement_currency_mismatch_map":{"eur":"2026-11-06T06:00:00Z"}}`)
		}},
		{"a marker Time.zone.parse reads loosely", "usd", "EUR", "", "settlement currency mismatch", func(t *testing.T, e *testEnv, conn *sql.DB) {
			charging(e)
			platform(t, conn, "usd", `{"settlement_currency_mismatch_map":{"eur":"Nov 6 2026"}}`)
		}},
		{"no platform account", "usd", "EUR", usdDefault, "", func(t *testing.T, e *testEnv, conn *sql.DB) { charging(e) }},
		{"a platform not holding USD", "usd", "EUR", "", "platform settlement currency", func(t *testing.T, e *testEnv, conn *sql.DB) {
			charging(e)
			platform(t, conn, "eur", `{}`)
		}},
		{"the seller's account without destination charges", "usd", "EUR", usdDefault, "", func(t *testing.T, e *testEnv, conn *sql.DB) {
			charging(e)
			platform(t, conn, "usd", `{}`)
			own(t, conn, "US", `{}`)
		}},
		{"the seller's account with destination charges", "usd", "EUR", eurLocal, "", func(t *testing.T, e *testEnv, conn *sql.DB) {
			charging(e)
			e.redis.HSet("buyer_currency_destination_charges", "boolean", "true")
			platform(t, conn, "usd", `{}`)
			own(t, conn, "US", `{}`)
		}},
		{"a cross-border account charges through the platform", "usd", "EUR", eurLocal, "", func(t *testing.T, e *testEnv, conn *sql.DB) {
			charging(e)
			platform(t, conn, "usd", `{}`)
			own(t, conn, "IN", `{}`)
		}},
		{"a Connect account", "usd", "EUR", "", "stripe connect account", func(t *testing.T, e *testEnv, conn *sql.DB) {
			charging(e)
			own(t, conn, "US", `{"meta":{"stripe_connect":"true"}}`)
		}},
		{"a USD buyer skips the charging checks", "eur", "USD",
			display("usd", "eur", "541", "1.0828956630028697", "buyer_local") + `,"buyer_currency":"usd",` +
				`"buyer_local_currency_rate":1.0828956630028697,"buyer_local_currency_subunit_to_unit":100,"buyer_local_price_cents":541,"rental_price_cents":`,
			"", func(t *testing.T, e *testEnv, conn *sql.DB) { charging(e) }},
		{"a single-unit buyer currency", "usd", "JPY",
			display("jpy", "usd", "776", "155.1234", "buyer_local") + `,"buyer_currency":"jpy",` +
				`"buyer_local_currency_rate":1.551234,"buyer_local_currency_subunit_to_unit":1,"buyer_local_price_cents":776,"rental_price_cents":`,
			"", nil},
		{"no rate", "usd", "EUR", usdDefault, "", func(t *testing.T, e *testEnv, conn *sql.DB) { e.redis.Del("currencies:EUR") }},
		{"a rate String#to_d reads loosely", "usd", "EUR", "", "currency rate", func(t *testing.T, e *testEnv, conn *sql.DB) {
			e.redis.Set("currencies:EUR", "0.9_2")
		}},
		{"seller turned it off", "usd", "EUR", usdDefault, "", func(t *testing.T, e *testEnv, conn *sql.DB) {
			conn.Exec("UPDATE users SET json_data = '{\"disable_buyer_local_currency\":true}' WHERE id = ?", sellerID)
		}},
	} {
		t.Run(c.name, func(t *testing.T) {
			e := newTestEnv(t)
			conn := testdb.Open(t)
			conn.Exec("UPDATE links SET price_currency_type = ? WHERE id = ?", c.product, productID)
			conn.Exec("UPDATE prices SET currency = ? WHERE id = ?", c.product, priceID)
			e.redis.HSet("buyer_local_currency", "boolean", "true")
			e.redis.Set("currencies:EUR", "0.92345")
			e.redis.Set("currencies:JPY", "155.1234")
			if c.setup != nil {
				c.setup(t, e, conn)
			}
			headers := map[string]string{"Cookie": "gumroad_buyer_currency=" + c.cookie}
			if c.reason != "" {
				maps.Copy(headers, e.dryRun(host, "/l/guide", testNow))
			}
			w := e.get(host, "/l/guide", headers)
			if c.reason != "" {
				if w.Code != http.StatusNoContent || w.Header().Get("X-Go-Web-Fallback") != c.reason {
					t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
				}
				return
			}
			if w.Code != http.StatusOK || e.railsHit != nil {
				t.Fatalf("%d %q, Rails hit: %v", w.Code, w.Header().Get("X-Go-Web-Fallback"), e.railsHit != nil)
			}
			page := html.UnescapeString(dataPage.FindStringSubmatch(w.Body.String())[1])
			if want := fmt.Sprintf(c.want, e.ids.Encrypt(productID)); !strings.Contains(page, want) {
				t.Errorf("want %s in %s", want, page[strings.Index(page, `"buyer_currency_display"`):][:420])
			}
		})
	}
}

func TestASellerRefundPolicyOffForAllRendersThePage(t *testing.T) {
	e := newTestEnv(t)
	conn := testdb.Open(t)
	conn.Exec("UPDATE users SET flags = flags | ? WHERE id = ?", userRefundPolicyEnabled, sellerID)
	t.Cleanup(func() {
		conn.Exec("UPDATE users SET flags = flags & ~? WHERE id = ?", userRefundPolicyEnabled, sellerID)
	})
	e.redis.HSet("seller_refund_policy_disabled_for_all", "boolean", "true")
	if w := e.get(host, "/l/guide", nil); w.Code != http.StatusOK || e.railsHit != nil {
		t.Errorf("%d, Rails hit: %v", w.Code, e.railsHit != nil)
	}
}

// Rails shows a visitor custom HTML only with the flag on, so saved but hidden HTML is the
// standard page.
func TestHiddenCustomHTMLRendersTheStandardPage(t *testing.T) {
	e := newTestEnv(t)
	testdb.Insert(t, testdb.Open(t), "pages", map[string]any{"id": int64(1_790_302), "pageable_type": "Link", "pageable_id": productID,
		"custom_html": "<h1>x</h1>", "created_at": testNow, "updated_at": testNow})
	if w := e.get(host, "/l/guide", nil); w.Code != http.StatusOK || e.railsHit != nil {
		t.Errorf("%d, Rails hit: %v", w.Code, e.railsHit != nil)
	}
}

func TestADryRunMakesNoCacheWrites(t *testing.T) {
	e := newTestEnv(t)
	e.redis.HSet("seller_reputation_summary", "boolean", "true")
	// A current snapshot, so the profile's rollup is computed and its cache write held back.
	e.redis.Set("seller_reputation_summary/v2/snapshot/1790001",
		`{"aggregate":[3,30,120],"signature":0,"computed_at":`+strconv.FormatInt(testNow.Unix(), 10)+`}`)
	if w := e.get(host, "/l/guide", e.dryRun(host, "/l/guide", testNow)); w.Code != http.StatusOK || len(e.cache.writes) != 0 {
		t.Fatalf("dry run: %d %q writes %v", w.Code, w.Header().Get("X-Go-Web-Fallback"), e.cache.writes)
	}
}

// testLog is where the app logs: stderr with GO_WEB_TEST_LOG set.
func testLog() io.Writer {
	if os.Getenv("GO_WEB_TEST_LOG") != "" {
		return os.Stderr
	}
	return io.Discard
}

// defaultStyles is custom_styles for a seller without a seller_profiles row.
func defaultStyles(t *testing.T) string {
	css, err := customstyles.CSS(customstyles.Profile{})
	if err != nil {
		t.Fatal(err)
	}
	return css
}
