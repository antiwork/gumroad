package products

import (
	"cmp"
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
	"reflect"
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
	"github.com/antiwork/gumroad/go_web/internal/elastic"
	"github.com/antiwork/gumroad/go_web/internal/flipper"
	"github.com/antiwork/gumroad/go_web/internal/inertia"
	"github.com/antiwork/gumroad/go_web/internal/obfuscate"
	"github.com/antiwork/gumroad/go_web/internal/pages"
	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/railscache"
	"github.com/antiwork/gumroad/go_web/internal/session"
	"github.com/antiwork/gumroad/go_web/internal/session/testdb"
	"github.com/antiwork/gumroad/go_web/internal/sidekiq"
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
	mu      sync.Mutex
	values  map[string]any
	ttls    map[string]time.Duration
	writes  []string
	readErr error
}

func (c *fakeCache) Read(_ context.Context, key string) (any, bool, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.readErr != nil {
		return nil, false, c.readErr
	}
	v, ok := c.values[key]
	return v, ok, nil
}

func (c *fakeCache) Write(_ context.Context, key string, value any, ttl time.Duration) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.values[key] = value
	if c.ttls == nil {
		c.ttls = map[string]time.Duration{}
	}
	c.ttls[key] = ttl
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
	config   *Config
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
	e.config = &Config{
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
			Layout: layout,
			CSP:    csp,
			Shared: pages.NewShared(env, func(context.Context) (bool, error) { return true, nil }),
			Avatars: &storage.Avatars{DB: conn, Exists: presentFiles{}, AssetHost: env.AssetHost(), Now: func() time.Time { return testNow },
				PublicStorage: "https://gumroad-public-storage.s3.amazonaws.com/", PublicCDN: "https://public-files.gumroad.com/"},
			Cache: e.cache,
			Redis: redisClient,
			Flag: func(name string) *flipper.Flag {
				if flags[name] == nil {
					flags[name] = flipper.New(redisClient, name)
				}
				return flags[name]
			},
			CalendarHref: calendarHref(t, manifest),
			CDNMap: [][2]string{{"https://s3.amazonaws.com/gumroad/", "https://static-2.gumroad.com/res/gumroad/"},
				{"https://gumroad-public-storage.s3.amazonaws.com/", "https://public-files.gumroad.com/"}},
			PublicStorageURL: "https://gumroad-public-storage.s3.amazonaws.com/",
			OGNamespace:      "gumroad",
			NewNonce:         func() string { return "NONCE" },
			GumroadAdminID:   767082,
			CustomHTMLAnalytics: &vite.Tags{HTML: `<script src="` + testAnalyticsScript + `" crossorigin="" type="module"></script>`,
				Links: []string{"<" + testAnalyticsScript + ">; rel=modulepreload; as=script; crossorigin=; nopush"}},
		},
		DryRunKey:  pages.DryRunKey(testSecretKeyBase),
		DryRunOnce: redisClient,
	}
	Register(app, e.config)
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
	return e.request(http.MethodGet, hostname, target, headers)
}

func (e *testEnv) request(method, hostname, target string, headers map[string]string) *httptest.ResponseRecorder {
	e.t.Helper()
	e.railsHit = nil
	r := httptest.NewRequest(method, target, nil)
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

// withDryRun is headers, plus a dry run's for target when a fallback reason is expected.
func (e *testEnv) withDryRun(target string, headers map[string]string, reason string) map[string]string {
	headers = maps.Clone(headers)
	if reason == "" {
		return headers
	}
	if headers == nil {
		headers = map[string]string{}
	}
	maps.Copy(headers, e.dryRun(host, target, testNow))
	return headers
}

// render GETs /l/guide, as a dry run when reason is set, and fails unless the page renders
// here or goes to Rails for reason. body is the unescaped page, "" after a fallback.
func (e *testEnv) render(t *testing.T, headers map[string]string, reason string) (body string) {
	t.Helper()
	body, _ = e.renderAt(t, "/l/guide", headers, reason)
	return body
}

// renderAt is render at target, with the response's headers.
func (e *testEnv) renderAt(t *testing.T, target string, headers map[string]string, reason string) (string, http.Header) {
	t.Helper()
	w := e.get(host, target, e.withDryRun(target, headers, reason))
	if reason != "" {
		if w.Code != http.StatusNoContent || w.Header().Get("X-Go-Web-Fallback") != reason {
			t.Fatalf("%d %q, want fallback %q", w.Code, w.Header().Get("X-Go-Web-Fallback"), reason)
		}
		return "", w.Header()
	}
	if w.Code != http.StatusOK || e.railsHit != nil {
		t.Fatalf("%d %q, Rails hit: %v", w.Code, w.Header().Get("X-Go-Web-Fallback"), e.railsHit != nil)
	}
	return html.UnescapeString(w.Body.String()), w.Header()
}

// wantAll fails for each want body lacks, once its %[n]s are the external ids of ids.
func (e *testEnv) wantAll(t *testing.T, body string, wants []string, ids ...int64) {
	t.Helper()
	args := make([]any, len(ids))
	for i, id := range ids {
		args[i] = e.ids.Encrypt(id)
	}
	for _, want := range wants {
		if strings.Contains(want, "%[") {
			want = fmt.Sprintf(want, args...)
		}
		if !strings.Contains(body, want) {
			t.Errorf("want %s", want)
		}
	}
}

func calendarHref(t *testing.T, manifest *vite.Manifest) string {
	href, err := manifest.AssetPath("components/ui/Calendar.tsx")
	if err != nil {
		t.Fatal(err)
	}
	return href
}

// eurCookie asks for prices in euros, which localEUR shows at rate euros to the dollar.
var eurCookie = map[string]string{"Cookie": "gumroad_buyer_currency=EUR"}

func (e *testEnv) localEUR(rate string) {
	e.redis.HSet("buyer_local_currency", "boolean", "true")
	e.redis.Set("currencies:EUR", rate)
}

// insertOfferCode adds an offer code of the seller's.
func insertOfferCode(t *testing.T, conn *sql.DB, id int64, columns map[string]any) {
	row := map[string]any{"id": id, "user_id": sellerID, "created_at": testNow, "updated_at": testNow}
	maps.Copy(row, columns)
	testdb.Insert(t, conn, "offer_codes", row)
}

// insertCodeUse adds a successful purchase of the product through the code.
func insertCodeUse(t *testing.T, conn *sql.DB, id, code int64, columns map[string]any) {
	row := map[string]any{"id": id, "seller_id": sellerID, "link_id": productID, "offer_code_id": code, "purchase_state": "successful",
		"quantity": 1, "created_at": testNow, "updated_at": testNow}
	maps.Copy(row, columns)
	testdb.Insert(t, conn, "purchases", row)
}

// insertExcludedProduct leaves product out of the code.
func insertExcludedProduct(t *testing.T, conn *sql.DB, id, code, product int64) {
	testdb.Insert(t, conn, "offer_codes_excluded_products", map[string]any{"id": id, "offer_code_id": code,
		"product_id": product, "created_at": testNow, "updated_at": testNow})
}

// insertPlatformAccount adds MerchantAccount.gumroad("stripe").
func insertPlatformAccount(t *testing.T, conn *sql.DB, currency, jsonData string) {
	testdb.Insert(t, conn, "merchant_accounts", map[string]any{"id": int64(1_790_901), "charge_processor_id": "stripe",
		"currency": currency, "json_data": jsonData, "created_at": testNow, "updated_at": testNow})
}

// insertInstallmentPlan adds a three-installment plan to the product.
func insertInstallmentPlan(t *testing.T, conn *sql.DB, id int64, recurrence string, deletedAt any) {
	testdb.Insert(t, conn, "product_installment_plans", map[string]any{"id": id, "link_id": productID, "number_of_installments": 3,
		"recurrence": recurrence, "deleted_at": deletedAt, "created_at": testNow, "updated_at": testNow})
}

// preorder puts the product in preorder, with a preorder link releasing at releaseAt.
func preorder(t *testing.T, conn *sql.DB, releaseAt any) {
	conn.Exec("UPDATE links SET flags = flags | ? WHERE id = ?", productIsInPreorderState, productID)
	testdb.Insert(t, conn, "preorder_links", map[string]any{"id": int64(1_793_101), "link_id": productID, "release_at": releaseAt,
		"created_at": testNow, "updated_at": testNow})
}

var dataPage = regexp.MustCompile(`data-page="([^"]*)"`)

func pageProps(t *testing.T, body string) map[string]any {
	t.Helper()
	return componentProps(t, body, productComponent)
}

func componentProps(t *testing.T, body, component string) map[string]any {
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

// retina_variant raises for a type ActiveStorage can't resize, and url_from_file's rescue serves
// the upload, queueing nothing.
func TestAnInvariableCoverServesItsUpload(t *testing.T) {
	e := newTestEnv(t)
	jobs := sidekiqJobs(t, e)
	addCover(t, false)
	mustExec(t, testdb.Open(t), "UPDATE active_storage_blobs SET content_type = 'image/svg+xml', filename = 'a.svg' WHERE id = ?", 1_790_501)
	w := e.get(host, "/l/guide", nil)
	if w.Code != http.StatusOK || e.railsHit != nil {
		t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
	cover := pageProps(t, w.Body.String())["product"].(map[string]any)["covers"].([]any)[0].(map[string]any)
	if original := "https://public-files.gumroad.com/covers/original"; cover["url"] != original || cover["original_url"] != original {
		t.Errorf("cover %v", cover)
	}
	if jobs.Exists("queue:low") {
		t.Error("an invariable cover queued its retina variant")
	}
}

// url_from_file enqueues the missing variant and serves the original until it's processed.
func TestACoverWithoutItsRetinaVariantQueuesIt(t *testing.T) {
	e := newTestEnv(t)
	jobs := sidekiqJobs(t, e)
	addCover(t, false)
	original := "https://public-files.gumroad.com/covers/original"
	render := func(headers map[string]string) {
		t.Helper()
		w := e.get(host, "/l/guide", headers)
		if w.Code != http.StatusOK {
			t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
		}
		body := w.Body.String()
		cover := pageProps(t, body)["product"].(map[string]any)["covers"].([]any)[0].(map[string]any)
		if cover["url"] != original || !strings.Contains(body, `<meta property="og:image" content="`+original+`"`) {
			t.Errorf("cover %v", cover)
		}
	}
	render(e.dryRun(host, "/l/guide", testNow))
	if jobs.Exists("queue:low") {
		t.Fatal("a dry run queued the variant")
	}
	render(nil)
	queued, _ := jobs.List("queue:low")
	if len(queued) != 1 || !strings.Contains(queued[0], `"args":[1790401],"class":"ProcessAssetPreviewRetinaWorker"`) {
		t.Errorf("queue:low %v", queued)
	}
	if slices.Contains(e.cache.writes, "attachment_1790601_retina_url") {
		t.Errorf("cache writes %v", e.cache.writes)
	}
	// lock: :until_executed holds while that job waits.
	render(nil)
	if queued, _ := jobs.List("queue:low"); len(queued) != 1 {
		t.Errorf("%d jobs queued", len(queued))
	}
}

// A blob the analyzer never measured has no retina_width: its variant is resize_to_limit [nil, nil],
// not processed yet here, so the cover queues it and serves the original, with no sizes.
func TestAnUnmeasuredCoverQueuesItsRetinaVariant(t *testing.T) {
	e := newTestEnv(t)
	jobs := sidekiqJobs(t, e)
	addCover(t, false)
	conn := testdb.Open(t)
	mustExec(t, conn, `UPDATE active_storage_blobs SET metadata = '{"identified":true}' WHERE id = ?`, 1_790_501)
	// Ruby's digest of {format: "jpg", resize_to_limit: [1005, nil]}, for the measured cover.
	testdb.Insert(t, conn, "active_storage_variant_records", map[string]any{"id": int64(1_790_701), "blob_id": int64(1_790_501),
		"variation_digest": "WX6OQ3hf/g9WoAI2n/sUdFF1vxA="})
	w := e.get(host, "/l/guide", nil)
	if w.Code != http.StatusOK || e.railsHit != nil {
		t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
	cover := pageProps(t, w.Body.String())["product"].(map[string]any)["covers"].([]any)[0].(map[string]any)
	original := "https://public-files.gumroad.com/covers/original"
	for key, want := range map[string]any{"url": original, "original_url": original, "width": nil, "height": nil,
		"native_width": nil, "native_height": nil} {
		if got := cover[key]; got != want {
			t.Errorf("cover %s = %#v, want %#v", key, got, want)
		}
	}
	queued, _ := jobs.List("queue:low")
	if len(queued) != 1 || !strings.Contains(queued[0], `"args":[1790401],"class":"ProcessAssetPreviewRetinaWorker"`) {
		t.Errorf("queue:low %v", queued)
	}
}

// sidekiqJobs gives e a Sidekiq client on a fresh Redis, which it returns.
func sidekiqJobs(t *testing.T, e *testEnv) *miniredis.Miniredis {
	jobs := miniredis.RunT(t)
	e.config.Page.Sidekiq = &sidekiq.Client{Redis: redis.NewClient(&redis.Options{Addr: jobs.Addr()}), RedisVersion: "7.2.4"}
	return jobs
}

// The redirect to checkout queues it too, as prepare_product_page reads the covers first.
func TestWantedQueuesACoversRetinaVariant(t *testing.T) {
	e := newTestEnv(t)
	jobs := sidekiqJobs(t, e)
	addCover(t, false)
	if w := e.get(host, "/l/guide?wanted=true", e.dryRun(host, "/l/guide?wanted=true", testNow)); w.Code != http.StatusFound {
		t.Fatalf("dry run: %d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
	if jobs.Exists("queue:low") {
		t.Fatal("a dry run queued the variant")
	}
	if w := e.get(host, "/l/guide?wanted=true", nil); w.Code != http.StatusFound {
		t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
	if queued, _ := jobs.List("queue:low"); len(queued) != 1 {
		t.Errorf("queue:low %v", queued)
	}
}

func TestAFailedRetinaVariantPushGoesToRails(t *testing.T) {
	e := newTestEnv(t)
	jobs := miniredis.RunT(t)
	e.config.Page.Sidekiq = &sidekiq.Client{Redis: redis.NewClient(&redis.Options{Addr: jobs.Addr(), MaxRetries: -1}), RedisVersion: "7.2.4"}
	jobs.Close()
	addCover(t, false)
	if e.get(host, "/l/guide", nil); e.railsHit == nil || len(e.cache.writes) != 0 {
		t.Errorf("rails %v, cache writes %v", e.railsHit != nil, e.cache.writes)
	}
}

func TestACoverWithoutItsRetinaVariantOrSidekiqGoesToRails(t *testing.T) {
	e := newTestEnv(t)
	addCover(t, false)
	e.render(t, nil, "retina variant push")
}

// A featured product's covers queue their variants with the page's.
func TestAFeaturedProductsCoverWithoutItsRetinaVariantQueuesIt(t *testing.T) {
	const featured, preview = int64(1_795_611), int64(1_795_621)
	e := newTestEnv(t)
	jobs := sidekiqJobs(t, e)
	conn := testdb.Open(t)
	testdb.Insert(t, conn, "links", map[string]any{"id": featured, "user_id": sellerID, "name": "Featured", "unique_permalink": "gowebfp",
		"price_cents": 700, "created_at": testNow, "updated_at": testNow})
	testdb.Insert(t, conn, "prices", map[string]any{"id": int64(1_795_612), "link_id": featured, "price_cents": 700, "currency": "usd",
		"created_at": testNow, "updated_at": testNow})
	testdb.Insert(t, conn, "asset_previews", map[string]any{"id": preview, "link_id": featured, "guid": "featured-cover",
		"position": 0, "created_at": testNow, "updated_at": testNow})
	addBlob(t, conn, 1_795_631, "covers/featured", "f.jpg", "image/jpeg", `{"identified":true,"width":2000,"height":1000,"analyzed":true}`)
	addAttachment(t, conn, 1_795_641, "file", "AssetPreview", preview, 1_795_631)
	addSection(t, conn, 1_792_651, profileFeaturedSectionType, "Pick", fmt.Sprintf(`{"featured_product_id":%d}`, featured))
	listSections(t, conn, `{"sections":[1792651]}`)
	e.render(t, nil, "")
	queued, _ := jobs.List("queue:low")
	if len(queued) != 1 || !strings.Contains(queued[0], `"args":[1795621],"class":"ProcessAssetPreviewRetinaWorker"`) {
		t.Errorf("queue:low %v", queued)
	}
}

// A dry run renders the wrapper of a cover without its retina variant and queues nothing.
func TestCustomHTMLWithoutACoversRetinaVariantInADryRun(t *testing.T) {
	e := newTestEnv(t)
	jobs := sidekiqJobs(t, e)
	addCover(t, false)
	customHTML(t, e, testdb.Open(t))
	if w := e.get(host, "/l/guide", e.dryRun(host, "/l/guide", testNow)); w.Code != http.StatusOK || e.railsHit != nil {
		t.Errorf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
	if jobs.Exists("queue:low") {
		t.Error("a dry run queued the variant")
	}
}

func TestAnotherSpellingOfThePermalinkRedirectsPermanently(t *testing.T) {
	e := newTestEnv(t)
	w := e.get(host, "/l/gowebp1?a%20b=1", nil)
	if w.Code != http.StatusMovedPermanently || w.Header().Get("Location") != "https://"+host+"/l/guide?a%20b=1" {
		t.Errorf("%d %q", w.Code, w.Header().Get("Location"))
	}
	// A code with a trailing slash, which the redirect leaves off.
	w = e.get(host, "/l/gowebp1/feed/", nil)
	if w.Code != http.StatusMovedPermanently || w.Header().Get("Location") != "https://"+host+"/l/guide/feed" {
		t.Errorf("code: %d %q", w.Code, w.Header().Get("Location"))
	}
}

func TestABannedOrMissingProductIsNotFound(t *testing.T) {
	e := newTestEnv(t)
	if w := e.get(host, "/l/nope", nil); w.Code != http.StatusNotFound || len(w.Header().Values("Set-Cookie")) != 0 {
		t.Errorf("missing: %d %v", w.Code, w.Header())
	}
	// A subdomain without a seller reaches the catch-all route's 404.
	if w := e.get("nosuchseller.gumroad.com", "/l/guide", nil); w.Code != http.StatusNotFound || e.railsHit != nil ||
		len(w.Header().Values("Set-Cookie")) != 0 {
		t.Errorf("no seller: %d %v", w.Code, w.Header())
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
		{name: "an empty code before a format", host: host, target: "/l/guide/.json", reason: "offer code path"},
		{name: "an offer_code param that isn't a plain string", host: host, target: "/l/guide?offer_code[]=X", reason: "param offer_code"},
		{name: "a code param that isn't a plain string", host: host, target: "/l/guide?code[]=X", reason: "param code"},
		{name: "a code param in other letters", host: host, target: "/l/guide?code=%CE%A3", reason: "param code"},
		{name: "a code param with punctuation", host: host, target: "/l/guide?code=SAVE.10", reason: "param code"},
		// An escaped slash stays in the code, as in Journey; only a literal trailing one is dropped.
		{name: "a path code ending in an escaped slash", host: host, target: "/l/guide/save10%2F", reason: "offer code path"},
		{name: "an escaped slash before a trailing one", host: host, target: "/l/guide/save10%2F/", reason: "offer code path"},
		// ServeMux would redirect it to its cleaned form; Rails routes it as it is.
		{name: "a path with a doubled slash", host: host, target: "/l/url(https://fonts.example.com/css", reason: "unclean path"},
		{name: "the custom HTML page's frame", host: host, target: "/l/guide/landing/embed", reason: "landing route"},
		{name: "the custom HTML page's live reload", host: host, target: "/l/guide/landing/version.json", reason: "landing route"},
		{name: "a utm visit without Sidekiq", host: host, target: "/l/guide?utm_source=a&utm_medium=b&utm_campaign=c", reason: "utm visit push"},
		{name: "the analytics host's route", host: "gumroad-analytics-com.gumroad.com", target: "/l/guide", reason: "host"},
		{name: "a Forwarded header", host: host, target: "/l/guide", reason: "forwarded header",
			headers: map[string]string{"Forwarded": "host=other.gumroad.com"}},
		{name: "a forwarded port", host: host, target: "/l/guide", reason: "port", headers: map[string]string{"X-Forwarded-Port": "8443"}},
		// The middleware reads a blank X-Inertia as no visit, the renderer as one.
		{name: "a blank X-Inertia", host: host, target: "/l/guide", reason: "inertia visit", headers: map[string]string{"X-Inertia": " "}},
		{name: "a partial reload", host: host, target: "/l/guide", reason: "inertia header X-Inertia-Partial-Component",
			headers: map[string]string{"X-Inertia": "true", "X-Inertia-Partial-Component": "Products/Show", "X-Inertia-Partial-Data": "product"}},
		{name: "a visit with a version", host: host, target: "/l/guide", reason: "inertia header X-Inertia-Version",
			headers: map[string]string{"X-Inertia": "true", "X-Inertia-Version": "1"}},
		{name: "storefront", host: host, target: "/l/guide", reason: "storefront",
			setup: func() {
				conn.Exec("UPDATE users SET flags = flags | ? WHERE id = ?", userProductPageStorefrontEnabled, sellerID)
			},
			undo: func() {
				conn.Exec("UPDATE users SET flags = flags & ~? WHERE id = ?", userProductPageStorefrontEnabled, sellerID)
			}},
		{name: "tiers without recurring billing", host: host, target: "/l/guide", reason: "tiers without recurring billing",
			setup: func() {
				conn.Exec("UPDATE links SET flags = flags | ? WHERE id = ?", productIsTieredMembership, productID)
			},
			undo: func() {
				conn.Exec("UPDATE links SET flags = flags & ~? WHERE id = ?", productIsTieredMembership, productID)
			}},
		{name: "an unknown purchase type", host: host, target: "/l/guide", reason: "purchase type",
			setup: func() { conn.Exec("UPDATE links SET purchase_type = 3 WHERE id = ?", productID) },
			undo:  func() { conn.Exec("UPDATE links SET purchase_type = 0 WHERE id = ?", productID) }},
		{name: "the seller's refund policy", host: host, target: "/l/guide", reason: "seller refund policy",
			setup: func() {
				conn.Exec("UPDATE users SET flags = flags | ? WHERE id = ?", userRefundPolicyEnabled, sellerID)
			},
			undo: func() {
				conn.Exec("UPDATE users SET flags = flags & ~? WHERE id = ?", userRefundPolicyEnabled, sellerID)
			}},
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

// Each case sets the purchase type and the fixture's buy price, then adds price rows. With a
// reason, the page goes to Rails.
func TestARentalRendersItsPrices(t *testing.T) {
	const offer = `"url":"https://gowebproductseller.gumroad.com/l/guide"`
	priceRow := func(id, cents int64, currency string, flags int) map[string]any {
		return map[string]any{"id": id, "link_id": productID, "price_cents": cents, "currency": currency, "flags": flags,
			"created_at": testNow, "updated_at": testNow}
	}
	rentalRow := func(id, cents int64) map[string]any { return priceRow(id, cents, "usd", 1) }
	for _, c := range []struct {
		name         string
		purchaseType int
		pwyw         bool
		buyCents     int64
		rows         []map[string]any
		want         []string
		missing      string
		reason       string
	}{
		{name: "buy and rent, the rental cheaper", purchaseType: 2, buyCents: 500,
			rows: []map[string]any{rentalRow(1_790_202, 400), rentalRow(1_790_203, 300)},
			want: []string{`"price_cents":500,`, `"rental_price_cents":300,`, `"rental":{"price_cents":300,"rent_only":false},`,
				`content="5.0" inertia="meta-property-product-price-amount"`, offer + `,"price":3.0}`}},
		{name: "rent only, with a stale buy price", purchaseType: 1, buyCents: 500, rows: []map[string]any{rentalRow(1_790_202, 300)},
			want: []string{`"price_cents":300,`, `"rental_price_cents":300,`, `"rental":{"price_cents":300,"rent_only":true},`,
				`content="3.0" inertia="meta-property-product-price-amount"`, offer + `,"price":3.0}`}},
		{name: "rent only, without a rental price", purchaseType: 1, buyCents: 500,
			want:    []string{`"price_cents":null,`, `"rental_price_cents":null,`, `"rental":null,`, offer + `}`},
			missing: "product:price:amount"},
		{name: "buy only, with a stale rental price", purchaseType: 0, buyCents: 500, rows: []map[string]any{rentalRow(1_790_202, 300)},
			want: []string{`"price_cents":500,`, `"rental_price_cents":null,`, `"rental":null,`, offer + `,"price":5.0}`}},
		{name: "pay what you want with a rental price", purchaseType: 2, pwyw: true, buyCents: 0, rows: []map[string]any{rentalRow(1_790_202, 300)},
			want: []string{`"pwyw":{"suggested_price_cents":null,"default_price_cents":null},`, offer + `,"price":0.0}`}},
		{name: "pay what you want with a free rental", purchaseType: 2, pwyw: true, buyCents: 0, rows: []map[string]any{rentalRow(1_790_202, 0)},
			want: []string{`"pwyw":{"suggested_price_cents":null,"default_price_cents":0},`, `"rental":{"price_cents":0,"rent_only":false},`}},
		// The meta tags read prices in SQL, under the column's collation.
		{name: "a buy price whose currency matches only under the collation", purchaseType: 0, buyCents: 500,
			rows: []map[string]any{priceRow(1_790_202, 300, "USD", 0)}, reason: "price currency collation"},
		{name: "a currency the collation pads with a control character", purchaseType: 0, buyCents: 500,
			rows: []map[string]any{priceRow(1_790_202, 300, "usd\x01", 0)}, reason: "price currency collation"},
		{name: "such a rental price on a buy-only product", purchaseType: 0, buyCents: 500,
			rows: []map[string]any{priceRow(1_790_202, 300, "USD", 1)}, want: []string{`"price_cents":500,`, `"rental":null,`}},
	} {
		t.Run(c.name, func(t *testing.T) {
			e := newTestEnv(t)
			conn := testdb.Open(t)
			if _, err := conn.Exec("UPDATE links SET purchase_type = ?, customizable_price = ? WHERE id = ?", c.purchaseType, c.pwyw, productID); err != nil {
				t.Fatal(err)
			}
			if _, err := conn.Exec("UPDATE prices SET price_cents = ? WHERE id = ?", c.buyCents, priceID); err != nil {
				t.Fatal(err)
			}
			for _, row := range c.rows {
				testdb.Insert(t, conn, "prices", row)
			}
			if c.reason != "" {
				w := e.get(host, "/l/guide", e.dryRun(host, "/l/guide", testNow))
				if w.Code != http.StatusNoContent || w.Header().Get("X-Go-Web-Fallback") != c.reason {
					t.Errorf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
				}
				return
			}
			w := e.get(host, "/l/guide", nil)
			if w.Code != http.StatusOK || e.railsHit != nil {
				t.Fatalf("%d, Rails hit: %v", w.Code, e.railsHit != nil)
			}
			body := html.UnescapeString(w.Body.String())
			for _, want := range c.want {
				if !strings.Contains(body, want) {
					t.Errorf("missing %s", want)
				}
			}
			if c.missing != "" && strings.Contains(body, c.missing) {
				t.Errorf("has %s", c.missing)
			}
		})
	}
}

// The fixture's price is the monthly one; tiers sit in a Tier category with their own prices.
func TestAMembershipRendersItsPrices(t *testing.T) {
	const yearly, quarterly, tierCategory, basic, pro = int64(1_792_001), int64(1_792_002), int64(1_792_101), int64(1_792_201), int64(1_792_202)
	price := func(t *testing.T, conn *sql.DB, id, cents int64, currency, recurrence string) {
		testdb.Insert(t, conn, "prices", map[string]any{"id": id, "link_id": productID, "price_cents": cents, "currency": currency,
			"recurrence": recurrence, "created_at": testNow, "updated_at": testNow})
	}
	membership := func(conn *sql.DB, flags int64) {
		conn.Exec("UPDATE links SET flags = flags | ?, subscription_duration = 0, native_type = 'membership' WHERE id = ?", flags, productID)
	}
	tier := func(t *testing.T, conn *sql.DB, id int64, name string, position int, maxPurchases any, flags int, prices ...[2]any) {
		testdb.Insert(t, conn, "base_variants", map[string]any{"id": id, "type": "Variant", "variant_category_id": tierCategory, "name": name,
			"position_in_category": position, "max_purchase_count": maxPurchases, "sales_count_for_inventory_cache": 2, "flags": flags,
			"created_at": testNow, "updated_at": testNow})
		for i, p := range prices {
			row := map[string]any{"id": id + int64(i+1)*1000, "variant_id": id, "price_cents": p[0], "currency": "usd", "recurrence": p[1],
				"created_at": testNow, "updated_at": testNow}
			if id == basic && i == 0 {
				row["suggested_price_cents"] = 350
			}
			testdb.Insert(t, conn, "prices", row)
		}
	}
	tiered := func(t *testing.T, conn *sql.DB, basicFlags, proFlags int) {
		membership(conn, productIsRecurringBilling|productIsTieredMembership)
		conn.Exec("UPDATE prices SET price_cents = 0, recurrence = 'monthly' WHERE id = ?", priceID)
		price(t, conn, yearly, 0, "usd", "yearly")
		testdb.Insert(t, conn, "variant_categories", map[string]any{"id": tierCategory, "link_id": productID, "title": "Tier"})
		tier(t, conn, basic, "Basic", 0, nil, basicFlags, [2]any{300, "monthly"}, [2]any{3000, "yearly"})
		tier(t, conn, pro, "Pro", 1, nil, proFlags, [2]any{900, "monthly"}, [2]any{1000, "quarterly"})
	}
	const offer = `"url":"https://gowebproductseller.gumroad.com/l/guide","price":`
	tierOption := func(id, name, quantityLeft, values string) string {
		return `{"id":"` + id + `","name":"` + name + `","quantity_left":` + quantityLeft + `,"description":"","price_difference_cents":null,` +
			`"recurrence_price_values":` + values + `,"is_pwyw":false,"duration_in_minutes":null}`
	}
	basicValues := `{"monthly":{"price_cents":300,"suggested_price_cents":350},"yearly":{"price_cents":3000,"suggested_price_cents":null}}`
	proValues := `{"monthly":{"price_cents":900,"suggested_price_cents":null}}`
	for _, c := range []struct {
		name    string
		wants   []string
		reason  string
		headers map[string]string
		setup   func(t *testing.T, e *testEnv, conn *sql.DB)
	}{
		{name: "a legacy subscription", wants: []string{`"price_cents":500,`,
			`"is_legacy_subscription":true,"is_tiered_membership":false,"is_recurring_billing":true,`, `"eligible_for_installment_plans":false,`,
			`"recurrences":{"default":"monthly","enabled":[{"recurrence":"monthly","price_cents":500,"id":"%[1]s","renewal_reminder_days":[]},` +
				`{"recurrence":"yearly","price_cents":4000,"id":"%[2]s","renewal_reminder_days":[]}],"free_trial_reminder_days":null},`,
			`"quantity":1,"recurrence":"monthly",`, offer + `5.0}`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				membership(conn, productIsRecurringBilling)
				conn.Exec("UPDATE prices SET recurrence = 'monthly' WHERE id = ?", priceID)
				price(t, conn, yearly, 4000, "usd", "yearly")
			}},
		// Every currency counts toward the recurrences and the offer.
		{name: "renewal reminders, and a cheaper price in another currency", wants: []string{
			`"enabled":[{"recurrence":"monthly","price_cents":500,"id":"%[1]s","renewal_reminder_days":[1]},` +
				`{"recurrence":"quarterly","price_cents":100,"id":"%[3]s","renewal_reminder_days":[7]},` +
				`{"recurrence":"yearly","price_cents":4000,"id":"%[2]s","renewal_reminder_days":[30,7]}]`, offer + `1.0}`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				e.redis.HSet("membership_renewal_reminders", "boolean", "true")
				membership(conn, productIsRecurringBilling)
				conn.Exec("UPDATE prices SET recurrence = 'monthly' WHERE id = ?", priceID)
				price(t, conn, yearly, 4000, "usd", "yearly")
				price(t, conn, quarterly, 100, "eur", "quarterly")
			}},
		{name: "a free trial", wants: []string{`"free_trial":{"duration":{"unit":"week","amount":1}},`, `"free_trial_reminder_days":2}`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				e.redis.HSet("membership_renewal_reminders", "boolean", "true")
				membership(conn, productIsRecurringBilling|productFreeTrialEnabled)
				conn.Exec("UPDATE links SET free_trial_duration_unit = 0, free_trial_duration_amount = 1 WHERE id = ?", productID)
				conn.Exec("UPDATE prices SET recurrence = 'monthly' WHERE id = ?", priceID)
			}},
		// A tier's price at a recurrence the product doesn't sell is left out.
		{name: "a tiered membership's tiers", wants: []string{`"price_cents":0,`,
			`"is_legacy_subscription":false,"is_tiered_membership":true,"is_recurring_billing":true,`, `"quantity_remaining":null,`,
			`"options":[` + tierOption("%[4]s", "Basic", "null", basicValues) + `,` + tierOption("%[5]s", "Pro", "null", proValues) + `]`,
			`content="0.0" inertia="meta-property-product-price-amount"`, `"availability":"https://schema.org/InStock",` + offer + `3.0}`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) { tiered(t, conn, 0, 0) }},
		// The offer then quotes the open tiers only.
		{name: "a tier closed to new buyers", wants: []string{tierOption("%[4]s", "Basic", "0", basicValues), offer + `9.0}`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				e.redis.HSet("close_membership_tier_to_new_buyers", "boolean", "true")
				tiered(t, conn, 4, 0)
			}},
		// The offer then quotes every tier.
		{name: "every tier closed", wants: []string{`"quantity_remaining":0,`, `"availability":"https://schema.org/SoldOut",` + offer + `3.0}`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				e.redis.HSet("close_membership_tier_to_new_buyers", "boolean", "true")
				tiered(t, conn, 4, 4)
			}},
		{name: "closed tiers without the flag", wants: []string{`"quantity_remaining":null,`, tierOption("%[5]s", "Pro", "null", proValues)},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) { tiered(t, conn, 4, 4) }},
		{name: "a lone tier's inventory", wants: []string{`"quantity_remaining":3,`}, setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			membership(conn, productIsRecurringBilling|productIsTieredMembership)
			testdb.Insert(t, conn, "variant_categories", map[string]any{"id": tierCategory, "link_id": productID, "title": "Tier"})
			tier(t, conn, basic, "Basic", 0, 5, 0, [2]any{300, "monthly"})
		}},
		{name: "no subscription duration", reason: "no subscription duration", setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			conn.Exec("UPDATE links SET flags = flags | ? WHERE id = ?", productIsRecurringBilling, productID)
		}},
		{name: "a subscription duration the enum doesn't map", reason: "subscription duration", setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			membership(conn, productIsRecurringBilling)
			conn.Exec("UPDATE links SET subscription_duration = 9 WHERE id = ?", productID)
		}},
		{name: "a free trial unit the enum doesn't map", reason: "free trial unit", setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			membership(conn, productIsRecurringBilling|productFreeTrialEnabled)
			conn.Exec("UPDATE links SET free_trial_duration_unit = 5 WHERE id = ?", productID)
		}},
		{name: "a rental membership", reason: "membership rental", setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			membership(conn, productIsRecurringBilling)
			conn.Exec("UPDATE links SET purchase_type = 2 WHERE id = ?", productID)
		}},
		{name: "a tiered membership with SKUs", reason: "tiered skus", setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			membership(conn, productIsRecurringBilling|productIsTieredMembership|productSkusEnabled|productIsPhysical)
		}},
		// The tiers ask MySQL whether the product sells at a recurrence, under the collation.
		{name: "a price recurrence that isn't exactly a name", reason: "price recurrence", setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			tiered(t, conn, 0, 0)
			conn.Exec("UPDATE prices SET recurrence = 'Yearly' WHERE id = ?", yearly)
		}},
		{name: "two prices at one recurrence", reason: "recurrence tie", setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			membership(conn, productIsRecurringBilling)
			price(t, conn, yearly, 4000, "usd", "yearly")
			price(t, conn, quarterly, 3500, "eur", "yearly")
		}},
		// Without buyer_currency_charging, buyer_currency_settleable? never asks the product's shape.
		{name: "a local price", headers: eurCookie, wants: []string{`"buyer_currency_shown":"eur",`, `"buyer_local_price_cents":462,`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				e.localEUR("0.92345")
				membership(conn, productIsRecurringBilling)
				conn.Exec("UPDATE prices SET recurrence = 'monthly' WHERE id = ?", priceID)
			}},
	} {
		t.Run(c.name, func(t *testing.T) {
			e := newTestEnv(t)
			c.setup(t, e, testdb.Open(t))
			e.wantAll(t, e.render(t, c.headers, c.reason), c.wants, priceID, yearly, quarterly, basic, pro)
		})
	}
}

// The bundle holds an ebook and, first by position, two of a course's Pro variant.
func TestABundleRendersItsProducts(t *testing.T) {
	const ebook, course, proVariant, courseCategory = int64(1_794_001), int64(1_794_002), int64(1_794_101), int64(1_794_201)
	member := func(t *testing.T, conn *sql.DB, id int64, name, permalink, nativeType string, cents int64, flags int64, maxPurchases any) {
		testdb.Insert(t, conn, "links", map[string]any{"id": id, "user_id": sellerID, "name": name, "unique_permalink": permalink,
			"native_type": nativeType, "price_cents": cents, "flags": flags, "max_purchase_count": maxPurchases,
			"sales_count_for_inventory_cache": 4, "created_at": testNow, "updated_at": testNow})
		testdb.Insert(t, conn, "prices", map[string]any{"id": id + 1000, "link_id": id, "price_cents": cents, "currency": "usd",
			"created_at": testNow, "updated_at": testNow})
	}
	const bundleID = productID
	item := func(t *testing.T, conn *sql.DB, id, productID int64, variantID any, quantity int, position any) {
		testdb.Insert(t, conn, "bundle_products", map[string]any{"id": id, "bundle_id": bundleID, "product_id": productID,
			"variant_id": variantID, "quantity": quantity, "position": position, "created_at": testNow, "updated_at": testNow})
	}
	setup := func(t *testing.T, conn *sql.DB, bundleFlag bool) {
		if bundleFlag {
			conn.Exec("UPDATE links SET flags = flags | ?, native_type = 'bundle' WHERE id = ?", productIsBundle, productID)
		}
		member(t, conn, ebook, "Ebook", "bp1", "ebook", 300, productDisplayReviews, 10)
		member(t, conn, course, "Course", "bp2", "course", 1000, 0, nil)
		conn.Exec("UPDATE links SET custom_permalink = 'ebook' WHERE id = ?", ebook)
		testdb.Insert(t, conn, "product_review_stats", map[string]any{"id": int64(1_794_501), "link_id": ebook, "reviews_count": 2, "average_rating": 4.5,
			"created_at": testNow, "updated_at": testNow})
		testdb.Insert(t, conn, "thumbnails", map[string]any{"id": int64(1_794_301), "product_id": ebook,
			"unsplash_url": "https://images.unsplash.com/x", "created_at": testNow, "updated_at": testNow})
		testdb.Insert(t, conn, "variant_categories", map[string]any{"id": courseCategory, "link_id": course, "title": "Edition"})
		testdb.Insert(t, conn, "base_variants", map[string]any{"id": proVariant, "type": "Variant", "variant_category_id": courseCategory,
			"name": "Pro", "price_difference_cents": 200, "max_purchase_count": 3, "sales_count_for_inventory_cache": 1,
			"created_at": testNow, "updated_at": testNow})
		item(t, conn, 1_794_401, ebook, nil, 1, 1)
		item(t, conn, 1_794_402, course, proVariant, 2, 0)
	}
	const courseProps = `{"id":"%[2]s","name":"Course","ratings":null,"price":2400,"currency_code":"usd","thumbnail_url":null,` +
		`"native_type":"course","url":"https://gowebproductseller.gumroad.com/l/bp2","quantity":2,"variant":"Pro"}`
	const ebookProps = `{"id":"%[1]s","name":"Ebook","ratings":{"count":2,"average":4.5},"price":300,"currency_code":"usd",` +
		`"thumbnail_url":"https://images.unsplash.com/x","native_type":"ebook","url":"https://gowebproductseller.gumroad.com/l/ebook",` +
		`"quantity":1,"variant":null}`
	const products = `"bundle_products":[` + courseProps + `,` + ebookProps + `]`
	for _, c := range []struct {
		name   string
		wants  []string
		reason string
		setup  func(t *testing.T, e *testEnv, conn *sql.DB)
	}{
		// The Pro variant has the fewest left: 2 of 3, against the ebook's 6 of 10.
		{name: "a bundle", wants: []string{products, `"quantity_remaining":2,`, `"file_summaries":{"product":null,"options":{}}`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) { setup(t, conn, true) }},
		{name: "a bundle hiding its products' reviews", wants: []string{`"name":"Ebook","ratings":null,`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				setup(t, conn, true)
				conn.Exec("UPDATE links SET flags = flags | ? WHERE id = ?", productHideBundleReviews, productID)
			}},
		{name: "a sold-out bundle product", wants: []string{`"quantity_remaining":0,`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				setup(t, conn, true)
				conn.Exec("UPDATE links SET sales_count_for_inventory_cache = 10 WHERE id = ?", ebook)
			}},
		// Rails lists them on any product; only a bundle counts their inventory.
		{name: "bundle products on a product that isn't a bundle", wants: []string{products, `"quantity_remaining":null,`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) { setup(t, conn, false) }},
		// Two tied rows come back in id order.
		{name: "bundle products tied in order", wants: []string{`"bundle_products":[` + ebookProps + `,` + courseProps + `]`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				setup(t, conn, true)
				conn.Exec("UPDATE bundle_products SET position = NULL WHERE bundle_id = ?", productID)
			}},
		{name: "a variant that's gone", wants: []string{`"native_type":"course","url":"https://gowebproductseller.gumroad.com/l/bp2","quantity":2,"variant":null}`,
			`"name":"Course","ratings":null,"price":2000,`, `"quantity_remaining":6,`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				setup(t, conn, true)
				conn.Exec("DELETE FROM base_variants WHERE id = ?", proVariant)
			}},
		{name: "another seller's product", reason: "bundle product seller", setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			setup(t, conn, true)
			conn.Exec("UPDATE links SET user_id = ? WHERE id = ?", sellerID+1, ebook)
		}},
		{name: "a bundle in the bundle", reason: "nested bundle", setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			setup(t, conn, true)
			conn.Exec("UPDATE links SET flags = flags | ? WHERE id = ?", productIsBundle, ebook)
		}},
		// has_one's preload keeps the first row its statement returns, here the lower id.
		{name: "two thumbnails", wants: []string{`"thumbnail_url":"https://images.unsplash.com/x","native_type":"ebook"`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				setup(t, conn, true)
				testdb.Insert(t, conn, "thumbnails", map[string]any{"id": int64(1_794_302), "product_id": ebook,
					"unsplash_url": "https://images.unsplash.com/y", "created_at": testNow, "updated_at": testNow})
			}},
		{name: "a missing product", reason: "bundle product missing", setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			setup(t, conn, true)
			conn.Exec("DELETE FROM links WHERE id = ?", ebook)
		}},
		// The row's variant is read alive or not; the course's own variants are all sold out.
		{name: "a bundle product with no variant in stock", wants: []string{`"quantity":2,"variant":"Pro"}`, `"quantity_remaining":0,`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				setup(t, conn, true)
				conn.Exec("UPDATE base_variants SET deleted_at = ? WHERE id = ?", testNow, proVariant)
				testdb.Insert(t, conn, "base_variants", map[string]any{"id": proVariant + 1, "type": "Variant", "variant_category_id": courseCategory,
					"name": "Basic", "max_purchase_count": 1, "sales_count_for_inventory_cache": 1, "created_at": testNow, "updated_at": testNow})
			}},
		{name: "a sold-out bundle with its own limit", wants: []string{`"availability":"https://schema.org/SoldOut"`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				setup(t, conn, true)
				conn.Exec("UPDATE links SET max_purchase_count = 5 WHERE id = ?", productID)
				conn.Exec("UPDATE links SET sales_count_for_inventory_cache = 10 WHERE id = ?", ebook)
			}},
		{name: "a rent-only bundle product", wants: []string{`"name":"Ebook","ratings":{"count":2,"average":4.5},"price":150,`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				setup(t, conn, true)
				conn.Exec("UPDATE links SET purchase_type = 1 WHERE id = ?", ebook)
				testdb.Insert(t, conn, "prices", map[string]any{"id": ebook + 2000, "link_id": ebook, "price_cents": 150, "currency": "usd",
					"flags": 1, "created_at": testNow, "updated_at": testNow})
			}},
		{name: "a deleted bundle product and a bundle file", wants: []string{products, `"attributes":[],`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				setup(t, conn, true)
				item(t, conn, 1_794_403, ebook, nil, 1, 2)
				conn.Exec("UPDATE bundle_products SET deleted_at = ? WHERE id = ?", testNow, 1_794_403)
				testdb.Insert(t, conn, "product_files", map[string]any{"id": int64(1_794_601), "link_id": productID, "filetype": "pdf", "size": 2048,
					"url": "https://s3.amazonaws.com/gumroad/attachments/x/y/original/a.pdf", "created_at": testNow, "updated_at": testNow})
			}},
		{name: "a bundle product with tiers", reason: "bundle product tiers", setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			setup(t, conn, true)
			conn.Exec("UPDATE variant_categories SET title = 'Tier' WHERE id = ?", courseCategory)
		}},
		{name: "a variant of another type", reason: "bundle product variant type", setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			setup(t, conn, true)
			conn.Exec("UPDATE base_variants SET type = 'Other' WHERE id = ?", proVariant)
		}},
		{name: "a bundle product's prices disagreeing", reason: "bundle product prices", setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			setup(t, conn, true)
			testdb.Insert(t, conn, "prices", map[string]any{"id": ebook + 2000, "link_id": ebook, "price_cents": 350, "currency": "usd",
				"created_at": testNow, "updated_at": testNow})
		}},
	} {
		t.Run(c.name, func(t *testing.T) {
			e := newTestEnv(t)
			c.setup(t, e, testdb.Open(t))
			e.wantAll(t, e.render(t, nil, c.reason), c.wants, ebook, course)
		})
	}
	// Past a handful of ties MySQL's sort leaves id order, so only Rails' own statement, written
	// here as Rails runs it, matches.
	t.Run("many bundle products tied in order", func(t *testing.T) {
		e := newTestEnv(t)
		conn := testdb.Open(t)
		setup(t, conn, true)
		conn.Exec("DELETE FROM bundle_products WHERE bundle_id = ?", bundleID)
		for i := range 60 {
			item(t, conn, 1_794_410+int64(i), ebook, nil, i+1, nil)
		}
		var want []string
		err := scanNamed(t.Context(), conn, func(cols map[string]any) func() {
			var quantity string
			cols["quantity"] = &quantity
			return func() { want = append(want, quantity) }
		}, "SELECT `bundle_products`.* FROM `bundle_products` WHERE `bundle_products`.`bundle_id` = "+strconv.FormatInt(bundleID, 10)+
			" AND `bundle_products`.`deleted_at` IS NULL ORDER BY `bundle_products`.`position` ASC")
		if err != nil {
			t.Fatal(err)
		}
		var got []string
		for _, m := range regexp.MustCompile(`"quantity":(\d+),"variant":null}`).FindAllStringSubmatch(e.render(t, nil, ""), -1) {
			got = append(got, m[1])
		}
		if !slices.Equal(got, want) {
			t.Errorf("got %v, want %v", got, want)
		}
	})
	// url_for_product_page carries the page's layout and recommended_by, sorted and CGI-escaped.
	t.Run("a layout and a recommendation", func(t *testing.T) {
		e := newTestEnv(t)
		setup(t, testdb.Open(t), true)
		w := e.get(host, "/l/guide?recommended_by=a+b%26c&layout=profile", nil)
		if w.Code != http.StatusOK || e.railsHit != nil {
			t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
		}
		want := `"url":"https://gowebproductseller.gumroad.com/l/bp2?layout=profile\u0026recommended_by=a+b%26c"`
		if page := html.UnescapeString(dataPage.FindStringSubmatch(w.Body.String())[1]); !strings.Contains(page, want) {
			t.Errorf("want %s", want)
		}
	})
	// Any other layout renders the product page, and its value still reaches the bundles' URLs.
	t.Run("another layout", func(t *testing.T) {
		e := newTestEnv(t)
		setup(t, testdb.Open(t), true)
		w := e.get(host, "/l/guide?layout=1%27+and+%22x%22", nil)
		if w.Code != http.StatusOK || e.railsHit != nil {
			t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
		}
		componentProps(t, w.Body.String(), productComponent)
		want := `"url":"https://gowebproductseller.gumroad.com/l/bp2?layout=1%27+and+%22x%22"`
		if page := html.UnescapeString(dataPage.FindStringSubmatch(w.Body.String())[1]); !strings.Contains(page, want) {
			t.Errorf("want %s", want)
		}
	})
}

// The fixture's price is 500 cents; each code is the seller's, with these columns set.
func TestDefaultOfferCodes(t *testing.T) {
	const autoID, explicitID = int64(1_795_001), int64(1_795_002)
	auto := func(t *testing.T, conn *sql.DB, columns map[string]any) {
		row := map[string]any{"code": "SALE20", "amount_percentage": 20, "universal": true, "auto_apply": true}
		maps.Copy(row, columns)
		insertOfferCode(t, conn, autoID, row)
	}
	explicit := func(t *testing.T, conn *sql.DB, columns map[string]any) {
		row := map[string]any{"code": "LAUNCH", "amount_cents": 100, "expires_at": time.Date(2026, 12, 1, 0, 0, 0, 0, time.UTC)}
		maps.Copy(row, columns)
		insertOfferCode(t, conn, explicitID, row)
		testdb.Insert(t, conn, "offer_codes_products", map[string]any{"id": int64(1_795_101), "offer_code_id": explicitID, "product_id": productID})
		conn.Exec("UPDATE links SET default_offer_code_id = ? WHERE id = ?", explicitID, productID)
	}
	discount := func(codeJSON string, rest string) string {
		return `{"valid":true,"code":` + codeJSON + `,"discount":` + rest + `}`
	}
	sale20 := discount(`"SALE20"`, `{"type":"percent","percents":20,"product_ids":null,"expires_at":null,"minimum_quantity":null,`+
		`"duration_in_billing_cycles":null,"minimum_amount_cents":null}`)
	launch := discount(`"LAUNCH"`, `{"type":"fixed","cents":100,"product_ids":["%[1]s"],"expires_at":"2026-12-01T00:00:00Z",`+
		`"minimum_quantity":null,"duration_in_billing_cycles":null,"minimum_amount_cents":null}`)
	future, past := time.Date(2026, 12, 1, 0, 0, 0, 0, time.UTC), time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)
	const category, first, second = int64(1_795_501), int64(1_795_601), int64(1_795_602)
	options := func(t *testing.T, conn *sql.DB, title string, secondFlags int) {
		testdb.Insert(t, conn, "variant_categories", map[string]any{"id": category, "link_id": productID, "title": title})
		for i, id := range []int64{first, second} {
			flags := 0
			if id == second {
				flags = secondFlags
			}
			testdb.Insert(t, conn, "base_variants", map[string]any{"id": id, "type": "Variant", "variant_category_id": category,
				"name": fmt.Sprint("Option ", i), "position_in_category": i, "flags": flags, "created_at": testNow, "updated_at": testNow})
			testdb.Insert(t, conn, "prices", map[string]any{"id": id + 1000, "variant_id": id, "price_cents": 300, "currency": "usd",
				"recurrence": "monthly", "created_at": testNow, "updated_at": testNow})
		}
	}
	saleEntry := `{"discount_code":` + sale20 + `,"sale_label":"Sale"}`
	// scopedSale is the sale with option_ids_by_product's JSON.
	scopedSale := func(optionIDs string) string {
		return discount(`"SALE20"`, `{"type":"percent","percents":20,"product_ids":null,"expires_at":null,"minimum_quantity":null,`+
			`"duration_in_billing_cycles":null,"minimum_amount_cents":null,"option_ids_by_product":`+optionIDs+`}`)
	}
	scope := func(t *testing.T, conn *sql.DB, id, variantID int64) {
		testdb.Insert(t, conn, "offer_codes_variants", map[string]any{"id": id, "offer_code_id": autoID, "variant_id": variantID})
	}
	// oncePerCart is the sale as a once-per-cart code of amount that allocates cents; %[6]s is its id.
	oncePerCart := func(cents, amount int, minimumQuantity string, limited bool) string {
		return `"discount_code":` + discount(`"SALE20"`, fmt.Sprintf(`{"type":"fixed","cents":%d,"product_ids":null,"expires_at":null,`+
			`"minimum_quantity":%s,"duration_in_billing_cycles":null,"minimum_amount_cents":null,"once_per_cart":true,`+
			`"once_per_cart_id":"%%[6]s","once_per_cart_amount_cents":%d,"once_per_cart_has_usage_limit":%t}`,
			cents, minimumQuantity, amount, limited)) + `,"sale_label":"Sale",`
	}
	exclude := insertExcludedProduct
	// otherID is another product of the seller's, which wantAll's %[4]s names.
	const otherID = int64(1_795_801)
	otherProduct := func(t *testing.T, conn *sql.DB, id int64, permalink string) {
		testdb.Insert(t, conn, "links", map[string]any{"id": id, "user_id": sellerID, "name": "Other", "unique_permalink": permalink,
			"price_cents": 300, "created_at": testNow, "updated_at": testNow})
	}
	excludingOther := strings.Replace(sale20, `"minimum_amount_cents":null}`, `"minimum_amount_cents":null,"excluded_product_ids":["%[4]s"]}`, 1)
	for _, c := range []struct {
		name, target string
		wants        []string
		reason       string
		headers      map[string]string
		setup        func(t *testing.T, e *testEnv, conn *sql.DB)
	}{
		{name: "an auto-applied percent code", wants: []string{`"discount_code":` + sale20 + `,"sale_label":"Sale",`,
			`"options":{"":` + saleEntry + `},"rent_options":null}`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) { auto(t, conn, nil) }},
		{name: "an auto-applied code's own label", wants: []string{`"sale_label":"Black Friday",`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				auto(t, conn, map[string]any{"sale_label": "Black Friday"})
			}},
		{name: "an explicit default", wants: []string{`"discount_code":` + launch + `,"sale_label":null,`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) { explicit(t, conn, nil) }},
		{name: "an expired explicit default", wants: []string{`"discount_code":null,"sale_label":null,`,
			`"options":{"":{"discount_code":null,"sale_label":null}},"rent_options":null}`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) { explicit(t, conn, map[string]any{"expires_at": past}) }},
		// default_offer_code has no alive scope; the lookups do.
		{name: "a deleted explicit default", wants: []string{`"discount_code":null,`, `"options":{"":{"discount_code":null,"sale_label":null}}`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) { explicit(t, conn, map[string]any{"deleted_at": past}) }},
		{name: "the sale over an expired explicit default", wants: []string{`"discount_code":` + sale20 + `,"sale_label":"Sale",`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				explicit(t, conn, map[string]any{"expires_at": past})
				auto(t, conn, nil)
			}},
		// Its uses left only count once it would otherwise win.
		{name: "the sale over a limited default that has ended", wants: []string{`"discount_code":` + sale20 + `,`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				explicit(t, conn, map[string]any{"expires_at": past, "max_purchase_count": 5})
				auto(t, conn, nil)
			}},
		{name: "the sale over a default for existing customers", wants: []string{`"discount_code":` + sale20 + `,"sale_label":"Sale",`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				explicit(t, conn, map[string]any{"existing_customers_only": true, "ownership_duration_tiers": `[{"months":12,"percent":10}]`})
				auto(t, conn, nil)
			}},
		{name: "a live explicit default over the sale", wants: []string{`"discount_code":` + launch + `,"sale_label":null,`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				explicit(t, conn, nil)
				auto(t, conn, nil)
			}},
		{name: "a new-customers auto row", wants: []string{`"discount_code":null,"sale_label":null,`, `"options":{},"rent_options":null}`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				auto(t, conn, map[string]any{"new_customers_only": true})
			}},
		{name: "a sale that leaves this product out", wants: []string{`"discount_code":null,`, `"options":{},"rent_options":null}`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				auto(t, conn, nil)
				exclude(t, conn, 1_795_701, autoID, productID)
			}},
		{name: "a sale that leaves another product out", wants: []string{`"discount_code":` + excludingOther + `,`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				auto(t, conn, nil)
				otherProduct(t, conn, otherID, "gowebp2")
				exclude(t, conn, 1_795_701, autoID, otherID)
			}},
		// excluded_products skips a join row whose product is gone.
		{name: "a sale that leaves out a product that's gone", wants: []string{`"discount_code":` + sale20 + `,`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				auto(t, conn, nil)
				exclude(t, conn, 1_795_701, autoID, otherID-1)
			}},
		{name: "a sale that leaves out a product that's gone and another", wants: []string{`"discount_code":` + excludingOther + `,`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				auto(t, conn, nil)
				otherProduct(t, conn, otherID, "gowebp2")
				exclude(t, conn, 1_795_701, autoID, otherID-1)
				exclude(t, conn, 1_795_702, autoID, otherID)
			}},
		{name: "a sale that leaves two products out", wants: []string{`"discount_code":` + strings.Replace(sale20, `"minimum_amount_cents":null}`,
			`"minimum_amount_cents":null,"excluded_product_ids":["%[4]s","%[5]s"]}`, 1) + `,`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				auto(t, conn, nil)
				otherProduct(t, conn, otherID, "gowebp2")
				otherProduct(t, conn, otherID+1, "gowebp3")
				exclude(t, conn, 1_795_701, autoID, otherID)
				exclude(t, conn, 1_795_702, autoID, otherID+1)
			}},
		// products comes in the join table's row order, not the products'.
		{name: "an explicit default for two products", wants: []string{`"discount_code":` +
			strings.Replace(launch, `"product_ids":["%[1]s"]`, `"product_ids":["%[4]s","%[1]s"]`, 1) + `,`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				explicit(t, conn, nil)
				otherProduct(t, conn, otherID, "gowebp2")
				testdb.Insert(t, conn, "offer_codes_products", map[string]any{"id": int64(1_795_100), "offer_code_id": explicitID, "product_id": otherID})
			}},
		// The preload keeps a duplicate join row, and skips one without a product.
		{name: "an explicit default with a duplicate and an empty join row", wants: []string{`"discount_code":` +
			strings.Replace(launch, `"product_ids":["%[1]s"]`, `"product_ids":["%[1]s","%[1]s"]`, 1) + `,`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				explicit(t, conn, nil)
				testdb.Insert(t, conn, "offer_codes_products", map[string]any{"id": int64(1_795_102), "offer_code_id": explicitID, "product_id": productID})
				testdb.Insert(t, conn, "offer_codes_products", map[string]any{"id": int64(1_795_103), "offer_code_id": explicitID})
			}},
		{name: "an explicit default whose other product is gone", wants: []string{`"discount_code":` + launch + `,`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				explicit(t, conn, nil)
				testdb.Insert(t, conn, "offer_codes_products", map[string]any{"id": int64(1_795_100), "offer_code_id": explicitID, "product_id": otherID})
			}},
		// Only a universal code lists what it leaves out.
		{name: "an explicit default with an exclusion row", wants: []string{`"discount_code":` + launch + `,`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				explicit(t, conn, nil)
				otherProduct(t, conn, otherID, "gowebp2")
				exclude(t, conn, 1_795_701, explicitID, otherID)
			}},
		{name: "a sale that hasn't started", wants: []string{`"discount_code":null,`, `"options":{"":{"discount_code":null,"sale_label":null}}`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) { auto(t, conn, map[string]any{"valid_at": future}) }},
		{name: "a fixed sale in another currency", wants: []string{`"discount_code":null,`, `"options":{},"rent_options":null}`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				auto(t, conn, map[string]any{"amount_percentage": nil, "amount_cents": 100, "currency_type": "eur"})
			}},
		// 400 and 500 cents through 0.92345.
		{name: "a local price for the sale", headers: eurCookie,
			wants: []string{`"buyer_local_price_cents":369,"buyer_local_original_price_cents":462,"rental_price_cents"`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				e.localEUR("0.92345")
				auto(t, conn, nil)
			}},
		{name: "a sale needing three", headers: eurCookie, wants: []string{`"minimum_quantity":3,`, `"buyer_local_price_cents":462,"rental_price_cents"`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				e.localEUR("0.92345")
				auto(t, conn, map[string]any{"minimum_quantity": 3})
			}},
		// (params[:quantity] || 1).to_i: the codes are weighed at it, and the price discounted from it.
		{name: "a sale needing three, for three", target: "/l/guide?quantity=3", headers: eurCookie,
			wants: []string{`"buyer_local_price_cents":369,"buyer_local_original_price_cents":462,`, `"url_code":null,"quantity":3,`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				e.localEUR("0.92345")
				auto(t, conn, map[string]any{"minimum_quantity": 3})
			}},
		{name: "a limited sale too short for the quantity", target: "/l/guide?quantity=2",
			wants: []string{`"discount_code":null,`, `"options":{"":{"discount_code":null,"sale_label":null}}`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				auto(t, conn, map[string]any{"max_purchase_count": 10})
				insertCodeUse(t, conn, 1_795_901, autoID, map[string]any{"quantity": 9})
			}},
		{name: "a once-per-cart sale over two units", target: "/l/guide?quantity=2", wants: []string{oncePerCart(600, 600, "null", false)},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				auto(t, conn, map[string]any{"amount_percentage": nil, "amount_cents": 600, "flags": offerCodeOncePerCart})
			}},
		// selection_discounts reads [quantity, 1].max; discount_code_props the quantity itself.
		{name: "a quantity under one", target: "/l/guide?quantity=abc", reason: "param quantity",
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) { auto(t, conn, nil) }},
		{name: "a quantity under one without a code", target: "/l/guide?quantity=abc", wants: []string{`"url_code":null,"quantity":1,`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {}},
		{name: "a quantity past int64", target: "/l/guide?quantity=99999999999999999999", reason: "param quantity",
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {}},
		{name: "an Array quantity", target: "/l/guide?quantity[]=2", reason: "param quantity",
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {}},
		// Ruby's Float#round: 999 * 0.15 = 149.85 rounds to 150.
		{name: "a percent rounding", headers: eurCookie, wants: []string{`"buyer_local_price_cents":849,"buyer_local_original_price_cents":999,`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				e.localEUR("1")
				conn.Exec("UPDATE prices SET price_cents = 999 WHERE id = ?", priceID)
				auto(t, conn, map[string]any{"amount_percentage": 15})
			}},
		{name: "a fixed sale over the price", headers: eurCookie, wants: []string{`"buyer_local_price_cents":0,"buyer_local_original_price_cents":500,`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				e.localEUR("1")
				auto(t, conn, map[string]any{"amount_percentage": nil, "amount_cents": 900})
			}},
		{name: "a rental's options", wants: []string{`"options":{"":` + saleEntry + `},"rent_options":{"":` + saleEntry + `}}`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				conn.Exec("UPDATE links SET purchase_type = 2 WHERE id = ?", productID)
				testdb.Insert(t, conn, "prices", map[string]any{"id": int64(1_795_201), "link_id": productID, "price_cents": 300, "currency": "usd",
					"flags": 1, "created_at": testNow, "updated_at": testNow})
				auto(t, conn, nil)
			}},
		{name: "each option's quote", wants: []string{`"options":{"%[2]s":` + saleEntry + `,"%[3]s":` + saleEntry + `},`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				options(t, conn, "Size", 0)
				auto(t, conn, nil)
			}},
		{name: "a tier closed to new buyers left out", wants: []string{`"options":{"%[2]s":` + saleEntry + `},`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				e.redis.HSet("close_membership_tier_to_new_buyers", "boolean", "true")
				conn.Exec("UPDATE links SET flags = flags | ?, subscription_duration = 0 WHERE id = ?",
					productIsRecurringBilling|productIsTieredMembership, productID)
				conn.Exec("UPDATE prices SET recurrence = 'monthly' WHERE id = ?", priceID)
				options(t, conn, "Tier", int(baseVariantClosedToNewPurchases))
				auto(t, conn, nil)
			}},
		{name: "a limited sale with uses left", wants: []string{`"discount_code":` + sale20 + `,"sale_label":"Sale",`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				auto(t, conn, map[string]any{"max_purchase_count": 10})
				insertCodeUse(t, conn, 1_795_901, autoID, map[string]any{"quantity": 9})
			}},
		{name: "a sold-out sale", wants: []string{`"discount_code":null,`, `"options":{"":{"discount_code":null,"sale_label":null}}`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				auto(t, conn, map[string]any{"max_purchase_count": 1})
				insertCodeUse(t, conn, 1_795_901, autoID, nil)
			}},
		// default_offer_code_uses_left? hands a used-up explicit default's place to the sale.
		{name: "the sale over a used-up default", wants: []string{`"discount_code":` + sale20 + `,"sale_label":"Sale",`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				explicit(t, conn, map[string]any{"max_purchase_count": 1})
				insertCodeUse(t, conn, 1_795_901, explicitID, nil)
				auto(t, conn, nil)
			}},
		{name: "the sale over a used-up once-per-cart default", wants: []string{`"discount_code":` + sale20 + `,"sale_label":"Sale",`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				explicit(t, conn, map[string]any{"max_purchase_count": 1, "flags": offerCodeOncePerCart})
				insertCodeUse(t, conn, 1_795_901, explicitID, nil)
				auto(t, conn, nil)
			}},
		{name: "a limited default with uses left over the sale", wants: []string{`"discount_code":` + launch + `,"sale_label":null,`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				explicit(t, conn, map[string]any{"max_purchase_count": 2})
				insertCodeUse(t, conn, 1_795_901, explicitID, nil)
				auto(t, conn, nil)
			}},
		// allocate_once_per_cart_discount takes the cents off the product's own line, up to its price
		// and short of leaving it under the currency's minimum.
		{name: "a once-per-cart sale", wants: []string{oncePerCart(100, 100, "null", false)}, setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			auto(t, conn, map[string]any{"amount_percentage": nil, "amount_cents": 100, "flags": offerCodeOncePerCart})
		}},
		{name: "a once-per-cart sale over the price", wants: []string{oncePerCart(500, 600, "null", false)},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				auto(t, conn, map[string]any{"amount_percentage": nil, "amount_cents": 600, "flags": offerCodeOncePerCart})
			}},
		{name: "a once-per-cart sale leaving less than the minimum", headers: eurCookie, wants: []string{oncePerCart(401, 450, "null", false),
			`"buyer_local_price_cents":99,"buyer_local_original_price_cents":500,`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				e.localEUR("1")
				auto(t, conn, map[string]any{"amount_percentage": nil, "amount_cents": 450, "flags": offerCodeOncePerCart})
			}},
		// It spends one use whatever the quantity, so one left serves a code of two, allocated
		// against both units.
		{name: "a once-per-cart sale of two with one use left", wants: []string{oncePerCart(600, 600, "2", true)},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				auto(t, conn, map[string]any{"amount_percentage": nil, "amount_cents": 600, "flags": offerCodeOncePerCart,
					"minimum_quantity": 2, "max_purchase_count": 1})
			}},
		{name: "a once-per-cart sale without a price", reason: "once-per-cart price", setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			conn.Exec("DELETE FROM prices WHERE id = ?", priceID)
			auto(t, conn, map[string]any{"amount_percentage": nil, "amount_cents": 100, "flags": offerCodeOncePerCart})
		}},
		{name: "a once-per-cart sale in an unknown currency", reason: "once-per-cart price", setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			conn.Exec("UPDATE links SET price_currency_type = 'xyz' WHERE id = ?", productID)
			conn.Exec("UPDATE prices SET currency = 'xyz' WHERE id = ?", priceID)
			auto(t, conn, map[string]any{"amount_percentage": nil, "amount_cents": 100, "flags": offerCodeOncePerCart, "currency_type": "xyz"})
		}},
		// The page quotes the sale without an option; each option outside its scope gets nothing.
		{name: "a sale for some options", wants: []string{
			`"discount_code":` + scopedSale(`{"%[1]s":["%[2]s"]}`) + `,"sale_label":"Sale",`,
			`"options":{"%[2]s":{"discount_code":` + scopedSale(`{"%[1]s":["%[2]s"]}`) + `,"sale_label":"Sale"},` +
				`"%[3]s":{"discount_code":null,"sale_label":null}},`,
		}, setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			options(t, conn, "Size", 0)
			auto(t, conn, nil)
			scope(t, conn, 1_795_301, first)
		}},
		// restricted_variants_for this product is empty, so every option gets the sale.
		{name: "a sale for another product's option", wants: []string{
			`"options":{"%[2]s":{"discount_code":` + scopedSale(`{"%[4]s":["%[5]s"]}`) + `,"sale_label":"Sale"},` +
				`"%[3]s":{"discount_code":` + scopedSale(`{"%[4]s":["%[5]s"]}`) + `,"sale_label":"Sale"}},`,
		}, setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			options(t, conn, "Size", 0)
			auto(t, conn, nil)
			testdb.Insert(t, conn, "base_variants", map[string]any{"id": otherID + 1, "type": "Sku", "link_id": otherID, "name": "Blue",
				"created_at": testNow, "updated_at": testNow})
			scope(t, conn, 1_795_301, otherID+1)
		}},
		// The variants join finds no row, so there's no option_ids_by_product.
		{name: "a sale for an option that's gone", wants: []string{`"discount_code":` + sale20 + `,"sale_label":"Sale",`, `"options":{"":` + saleEntry + `}`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				auto(t, conn, nil)
				scope(t, conn, 1_795_301, 1_795_699)
			}},
		{name: "a sale for an option without a product", reason: "offer code option product", setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			auto(t, conn, nil)
			testdb.Insert(t, conn, "base_variants", map[string]any{"id": otherID + 1, "type": "Variant", "variant_category_id": int64(1_795_599),
				"name": "Lost", "created_at": testNow, "updated_at": testNow})
			scope(t, conn, 1_795_301, otherID+1)
		}},
		// A page without options quotes no option, which every scope lets in.
		{name: "a sale for a deleted option", wants: []string{`"options":{"":{"discount_code":` + scopedSale(`{"%[1]s":["%[5]s"]}`) + `,"sale_label":"Sale"}}`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				auto(t, conn, nil)
				testdb.Insert(t, conn, "variant_categories", map[string]any{"id": int64(1_795_502), "link_id": productID, "title": "Size", "deleted_at": past})
				testdb.Insert(t, conn, "base_variants", map[string]any{"id": otherID + 1, "type": "Variant", "variant_category_id": int64(1_795_502),
					"name": "Gone", "deleted_at": past, "created_at": testNow, "updated_at": testNow})
				scope(t, conn, 1_795_301, otherID+1)
			}},
		{name: "a sale for an option of another type", reason: "offer code option type", setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			options(t, conn, "Size", 0)
			auto(t, conn, nil)
			conn.Exec("UPDATE base_variants SET type = 'Other' WHERE id = ?", first)
			scope(t, conn, 1_795_301, first)
		}},
		// The collation matches SALE20 to sale20, and both of Rails' lookups take the sale first.
		{name: "two codes MySQL can't tell apart", wants: []string{saleEntry}, setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			auto(t, conn, nil)
			insertOfferCode(t, conn, autoID+10, map[string]any{"code": "sale20", "amount_percentage": 5, "universal": true})
		}},
		// find_offer_code takes the product's code, and the computing service the first of the
		// seller's codes by that string that suits the product, the sale, at the found row's minimum.
		{name: "a product's code with the sale's string", wants: []string{`"discount_code":` + sale20 + `,"sale_label":"Sale",`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				auto(t, conn, nil)
				insertOfferCode(t, conn, autoID+10, map[string]any{"code": "sale20", "amount_percentage": 5})
				testdb.Insert(t, conn, "offer_codes_products", map[string]any{"id": int64(1_795_103), "offer_code_id": autoID + 10, "product_id": productID})
			}},
		// An older universal code by the sale's string comes first to both lookups, so the result has
		// its 5%, echoed under the sale's own string, which also earns the sale's label.
		{name: "an older code by the sale's string", wants: []string{`"discount_code":` + discount(`"SALE20"`, `{"type":"percent","percents":5,`+
			`"product_ids":null,"expires_at":null,"minimum_quantity":null,"duration_in_billing_cycles":null,"minimum_amount_cents":null}`) +
			`,"sale_label":"Sale",`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				insertOfferCode(t, conn, autoID-1, map[string]any{"code": "sale20", "amount_percentage": 5, "universal": true})
				auto(t, conn, nil)
			}},
		// Weighed at the product's code's minimum, one, the sale falls short of its own three.
		{name: "a sale by the product's code's string short of its own minimum", wants: []string{`"discount_code":null,`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				auto(t, conn, map[string]any{"minimum_quantity": 3})
				insertOfferCode(t, conn, autoID+10, map[string]any{"code": "sale20", "amount_percentage": 5})
				testdb.Insert(t, conn, "offer_codes_products", map[string]any{"id": int64(1_795_103), "offer_code_id": autoID + 10, "product_id": productID})
			}},
		// The sale is weighed at the product's code's minimum, which its own terms don't change.
		{name: "a product's code with the sale's string and another minimum", wants: []string{`"discount_code":` + sale20 + `,"sale_label":"Sale",`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				auto(t, conn, nil)
				insertOfferCode(t, conn, autoID+10, map[string]any{"code": "sale20", "amount_percentage": 5, "minimum_quantity": 2})
				testdb.Insert(t, conn, "offer_codes_products", map[string]any{"id": int64(1_795_103), "offer_code_id": autoID + 10, "product_id": productID})
			}},
		{name: "a sale in Latin letters", wants: []string{`"discount_code":` + discount(`"SOLDÉ"`, `{"type":"percent","percents":20,`+
			`"product_ids":null,"expires_at":null,"minimum_quantity":null,"duration_in_billing_cycles":null,"minimum_amount_cents":null}`) +
			`,"sale_label":"Sale",`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) { auto(t, conn, map[string]any{"code": "SOLDÉ"}) }},
		{name: "a code in other letters", reason: "offer code characters", setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			auto(t, conn, map[string]any{"code": "ΣALE"})
		}},
		// applicable? compares with ==, so no sale.
		{name: "a sale in a currency only the collation matches", wants: []string{`"discount_code":null,`, `"options":{},"rent_options":null}`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				auto(t, conn, map[string]any{"amount_percentage": nil, "amount_cents": 100, "currency_type": "USD"})
			}},
		{name: "a default in a currency only the collation matches", reason: "offer code currency", setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			explicit(t, conn, map[string]any{"amount_cents": nil, "amount_percentage": 10, "currency_type": "USD"})
		}},
	} {
		t.Run(c.name, func(t *testing.T) {
			e := newTestEnv(t)
			c.setup(t, e, testdb.Open(t))
			body, _ := e.renderAt(t, cmp.Or(c.target, "/l/guide"), c.headers, c.reason)
			e.wantAll(t, body, c.wants, productID, first, second, otherID, otherID+1, autoID)
		})
	}
	// option_ids_by_product keeps the order OfferCode#variants' own statement returns.
	t.Run("a sale for both options", func(t *testing.T) {
		e := newTestEnv(t)
		conn := testdb.Open(t)
		options(t, conn, "Size", 0)
		auto(t, conn, nil)
		scope(t, conn, 1_795_301, second)
		scope(t, conn, 1_795_302, first)
		ids, err := (&handler{c: e.config}).scanIDs(t.Context(), "SELECT `base_variants`.* FROM `base_variants` INNER JOIN `offer_codes_variants`"+
			" ON `base_variants`.`id` = `offer_codes_variants`.`variant_id` WHERE `offer_codes_variants`.`offer_code_id` = "+strconv.FormatInt(autoID, 10))
		if err != nil || len(ids) != 2 {
			t.Fatal(ids, err)
		}
		optionIDs := `{"` + e.ids.Encrypt(productID) + `":["` + e.ids.Encrypt(ids[0]) + `","` + e.ids.Encrypt(ids[1]) + `"]}`
		e.wantAll(t, e.render(t, nil, ""), []string{`"discount_code":` + scopedSale(optionIDs) + `,"sale_label":"Sale",`,
			`"options":{"%[1]s":{"discount_code":` + scopedSale(optionIDs) + `,"sale_label":"Sale"},"%[2]s":`}, first, second)
	})
}

// The fixture's price is 500 cents; SAVE10 is the seller's 10% code on every product.
func TestURLOfferCodes(t *testing.T) {
	const codeID, autoID = int64(1_796_001), int64(1_796_002)
	save10 := func(t *testing.T, conn *sql.DB, columns map[string]any) {
		row := map[string]any{"code": "SAVE10", "amount_percentage": 10, "universal": true}
		maps.Copy(row, columns)
		insertOfferCode(t, conn, codeID, row)
	}
	sale := func(t *testing.T, conn *sql.DB) {
		insertOfferCode(t, conn, autoID, map[string]any{"code": "SALE20", "amount_percentage": 20, "universal": true, "auto_apply": true})
	}
	valid := func(typed, extra string) string {
		return `{"valid":true,"code":"` + typed + `","discount":{"type":"percent","percents":10,"product_ids":null,"expires_at":null,` +
			`"minimum_quantity":null,"duration_in_billing_cycles":null,"minimum_amount_cents":null` + extra + `}}`
	}
	saleResult := `{"valid":true,"code":"SALE20","discount":{"type":"percent","percents":20,"product_ids":null,"expires_at":null,` +
		`"minimum_quantity":null,"duration_in_billing_cycles":null,"minimum_amount_cents":null}}`
	scoped30 := strings.Replace(valid("SAVE10", `,"option_ids_by_product":{"%[1]s":["%[3]s"]}`), `"percents":10`, `"percents":30`, 1)
	fixed150 := `{"valid":true,"code":"SAVE10","discount":{"type":"fixed","cents":150,"product_ids":null,"expires_at":null,` +
		`"minimum_quantity":null,"duration_in_billing_cycles":null,"minimum_amount_cents":null}}`
	invalid := func(errorCode string) string { return `{"valid":false,"error_code":"` + errorCode + `"}` }
	quotes := func(urlCode, result, label string) string {
		return `"selection_discounts":{"url_code":"` + urlCode + `","quantity":1,"recurrence":null,"option_id":null,"price_cents":null,` +
			`"options":{"":{"discount_code":` + result + `,"sale_label":` + label + `}},"rent_options":null}`
	}
	past, future := time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC), time.Date(2026, 12, 1, 0, 0, 0, 0, time.UTC)
	// sizes are two options, the code's scope the first; wantAll's %[3]s and %[4]s name them.
	const sizeCategory, small, large = int64(1_796_311), int64(1_796_312), int64(1_796_313)
	sizes := func(t *testing.T, conn *sql.DB, scoped int64) {
		testdb.Insert(t, conn, "variant_categories", map[string]any{"id": sizeCategory, "link_id": productID, "title": "Size"})
		for i, id := range []int64{small, large} {
			testdb.Insert(t, conn, "base_variants", map[string]any{"id": id, "type": "Variant", "variant_category_id": sizeCategory,
				"name": fmt.Sprint("Size ", i), "position_in_category": i, "created_at": testNow, "updated_at": testNow})
		}
		testdb.Insert(t, conn, "offer_codes_variants", map[string]any{"id": int64(1_796_301), "offer_code_id": scoped, "variant_id": small})
	}
	const smallOnly = `,"option_ids_by_product":{"%[1]s":["%[3]s"]}`
	optionQuotes := func(urlCode, smallResult, smallLabel, largeResult string) string {
		return `"selection_discounts":{"url_code":"` + urlCode + `","quantity":1,"recurrence":null,"option_id":null,"price_cents":null,` +
			`"options":{"%[3]s":{"discount_code":` + smallResult + `,"sale_label":` + smallLabel + `},` +
			`"%[4]s":{"discount_code":` + largeResult + `,"sale_label":null}},"rent_options":null}`
	}
	for _, c := range []struct {
		name, target string
		wants        []string
		reason       string
		headers      map[string]string
		// indexed is a page without set_x_robots_tag_header's noindex: no code.
		indexed bool
		setup   func(t *testing.T, e *testEnv, conn *sql.DB)
	}{
		// The result echoes the code as typed.
		{name: "a code in the path", target: "/l/guide/save10",
			wants: []string{`"discount_code":` + valid("save10", "") + `,"sale_label":null,`, quotes("save10", valid("save10", ""), "null")},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) { save10(t, conn, nil) }},
		// Journey drops the trailing slash.
		{name: "a code in the path with a trailing slash", target: "/l/guide/save10/",
			wants: []string{`"discount_code":` + valid("save10", "") + `,"sale_label":null,`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) { save10(t, conn, nil) }},
		{name: "a code in the query", target: "/l/guide?code=SAVE10", wants: []string{quotes("SAVE10", valid("SAVE10", ""), "null")},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) { save10(t, conn, nil) }},
		// (params[:offer_code] || params[:code]).presence: offer_code wins, a blank one hides the code,
		// and only code noindexes.
		{name: "an offer_code over a code", target: "/l/guide?offer_code=SAVE10&code=NOPE", wants: []string{quotes("SAVE10", valid("SAVE10", ""), "null")},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) { save10(t, conn, nil) }},
		{name: "an offer_code alone", target: "/l/guide?offer_code=SAVE10", indexed: true, wants: []string{quotes("SAVE10", valid("SAVE10", ""), "null")},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) { save10(t, conn, nil) }},
		{name: "a blank offer_code", target: "/l/guide?offer_code=&code=SAVE10", wants: []string{`"discount_code":null,"sale_label":null,`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) { save10(t, conn, nil) }},
		{name: "a once-per-cart code", target: "/l/guide/SAVE10", wants: []string{`"discount_code":{"valid":true,"code":"SAVE10",` +
			`"discount":{"type":"fixed","cents":500,"product_ids":null,"expires_at":null,"minimum_quantity":null,"duration_in_billing_cycles":null,` +
			`"minimum_amount_cents":null,"once_per_cart":true,"once_per_cart_id":"%[2]s","once_per_cart_amount_cents":600,` +
			`"once_per_cart_has_usage_limit":false}},"sale_label":null,`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				save10(t, conn, map[string]any{"amount_percentage": nil, "amount_cents": 600, "flags": offerCodeOncePerCart})
			}},
		{name: "an unknown code", target: "/l/guide/NOPE", wants: []string{quotes("NOPE", invalid("invalid_offer"), "null")}},
		// normalize_code's NFC and downcase, then the column's collation, which ignores a word
		// joiner but not a directional isolate.
		{name: "an accented code typed in capitals", target: "/l/guide?code=CAFE%CC%81",
			wants: []string{quotes("CAFE\u0301", valid("CAFE\u0301", ""), "null")},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) { save10(t, conn, map[string]any{"code": "café"}) }},
		{name: "a code with a word joiner pasted on", target: "/l/guide/SAVE10%E2%81%A0",
			wants: []string{quotes("SAVE10\u2060", valid("SAVE10\u2060", ""), "null")},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) { save10(t, conn, nil) }},
		{name: "a code with a directional isolate pasted on", target: "/l/guide/SAVE10%E2%81%A9",
			wants: []string{quotes("SAVE10\u2069", invalid("invalid_offer"), "null")},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) { save10(t, conn, nil) }},
		{name: "a deleted code", target: "/l/guide/SAVE10", wants: []string{`"discount_code":` + invalid("invalid_offer") + `,`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) { save10(t, conn, map[string]any{"deleted_at": past}) }},
		{name: "a code that leaves this product out", target: "/l/guide/SAVE10", wants: []string{`"discount_code":` + invalid("invalid_offer") + `,`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				save10(t, conn, nil)
				insertExcludedProduct(t, conn, 1_796_101, codeID, productID)
			}},
		{name: "a fixed code in another currency", target: "/l/guide/SAVE10", wants: []string{`"discount_code":` + invalid("invalid_offer") + `,`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				save10(t, conn, map[string]any{"amount_percentage": nil, "amount_cents": 100, "currency_type": "eur"})
			}},
		{name: "an expired code", target: "/l/guide/SAVE10", wants: []string{`"discount_code":` + invalid("inactive") + `,`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) { save10(t, conn, map[string]any{"expires_at": past}) }},
		{name: "a code not yet started", target: "/l/guide/SAVE10", wants: []string{`"discount_code":` + invalid("inactive") + `,`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) { save10(t, conn, map[string]any{"valid_at": future}) }},
		{name: "a code for existing customers", target: "/l/guide/SAVE10", wants: []string{`"discount_code":` + invalid("not_existing_customer") + `,`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				save10(t, conn, map[string]any{"existing_customers_only": true})
			}},
		{name: "an expired code for existing customers", target: "/l/guide/SAVE10", wants: []string{`"discount_code":` + invalid("inactive") + `,`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				save10(t, conn, map[string]any{"existing_customers_only": true, "expires_at": past})
			}},
		{name: "a code for new customers", target: "/l/guide/SAVE10", wants: []string{`"discount_code":` + valid("SAVE10", `,"new_customers_only":true`) + `,`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				save10(t, conn, map[string]any{"new_customers_only": true})
			}},
		{name: "the sale over an unknown code", target: "/l/guide/NOPE",
			wants: []string{`"discount_code":{"valid":true,"code":"SALE20",`, `"sale_label":"Sale",`, `"selection_discounts":{"url_code":"NOPE",`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) { sale(t, conn) }},
		{name: "a code over an expired default", target: "/l/guide/SAVE10", wants: []string{`"discount_code":` + valid("SAVE10", "") + `,"sale_label":null,`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				save10(t, conn, nil)
				insertOfferCode(t, conn, autoID, map[string]any{"code": "LAUNCH", "amount_cents": 100, "expires_at": past})
				testdb.Insert(t, conn, "offer_codes_products", map[string]any{"id": int64(1_796_201), "offer_code_id": autoID, "product_id": productID})
				conn.Exec("UPDATE links SET default_offer_code_id = ? WHERE id = ?", autoID, productID)
			}},
		{name: "a blank code", target: "/l/guide?code=", indexed: true,
			wants: []string{`"selection_discounts":{"url_code":null,`, `"options":{},"rent_options":null}`}},
		{name: "a code of spaces", target: "/l/guide?code=%20%20", indexed: true,
			wants: []string{`"selection_discounts":{"url_code":null,`, `"options":{},"rent_options":null}`}},
		{name: "the path's code over the query's", target: "/l/guide/SAVE10?code=NOPE", wants: []string{`"selection_discounts":{"url_code":"SAVE10",`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) { save10(t, conn, nil) }},
		// find_offer_code tries the product's own codes first.
		{name: "a code for this product", target: "/l/guide/SAVE10",
			wants: []string{`"discount_code":{"valid":true,"code":"SAVE10","discount":{"type":"percent","percents":10,"product_ids":["%[1]s"],`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				save10(t, conn, map[string]any{"universal": false})
				testdb.Insert(t, conn, "offer_codes_products", map[string]any{"id": int64(1_796_501), "offer_code_id": codeID, "product_id": productID})
			}},
		// 450 and 500 cents through 0.92345.
		{name: "a local price for the code", target: "/l/guide/SAVE10", headers: eurCookie,
			wants: []string{`"buyer_local_price_cents":416,"buyer_local_original_price_cents":462,"rental_price_cents"`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				e.localEUR("0.92345")
				save10(t, conn, nil)
			}},
		// BestOfferCodeService#result weighs the URL's code against the sale at the page's price and
		// at each option's: the URL's wins by taking more off, or when the sale's conditions fail.
		{name: "a code and a bigger sale", target: "/l/guide/SAVE10", wants: []string{quotes("SAVE10", saleResult, `"Sale"`)},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				save10(t, conn, nil)
				sale(t, conn)
			}},
		{name: "a code bigger than the sale", target: "/l/guide/SAVE10",
			wants: []string{quotes("SAVE10", strings.Replace(valid("SAVE10", ""), `"percents":10`, `"percents":30`, 1), "null")},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				save10(t, conn, map[string]any{"amount_percentage": 30})
				sale(t, conn)
			}},
		{name: "a code as big as the sale", target: "/l/guide/SAVE10", wants: []string{quotes("SAVE10", saleResult, `"Sale"`)},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				save10(t, conn, map[string]any{"amount_percentage": 20})
				sale(t, conn)
			}},
		{name: "a bigger code whose spend minimum fails", target: "/l/guide/SAVE10", wants: []string{quotes("SAVE10", saleResult, `"Sale"`)},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				save10(t, conn, map[string]any{"amount_percentage": 50, "minimum_amount_cents": 1000})
				sale(t, conn)
			}},
		// An option outside a code's scope weighs only the codes valid for it; with none, the URL's
		// code says why.
		{name: "a scoped code that beats the sale", target: "/l/guide/SAVE10", wants: []string{
			`"discount_code":` + scoped30 + `,"sale_label":null,`,
			`"options":{"%[3]s":{"discount_code":` + scoped30 + `,"sale_label":null},"%[4]s":{"discount_code":` + saleResult + `,"sale_label":"Sale"}},`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				save10(t, conn, map[string]any{"amount_percentage": 30})
				sale(t, conn)
				sizes(t, conn, codeID)
			}},
		{name: "a scoped code and sale both leaving an option out", target: "/l/guide/SAVE10", wants: []string{
			`"discount_code":` + scoped30 + `,"sale_label":null,`,
			`"options":{"%[3]s":{"discount_code":` + scoped30 + `,"sale_label":null},"%[4]s":{"discount_code":` + invalid("option_not_eligible") + `,"sale_label":null}},`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				save10(t, conn, map[string]any{"amount_percentage": 30})
				sale(t, conn)
				sizes(t, conn, codeID)
				testdb.Insert(t, conn, "offer_codes_variants", map[string]any{"id": int64(1_796_302), "offer_code_id": autoID, "variant_id": small})
			}},
		// $1.50 off beats 20% at 500 cents, so the page and the cheap option quote the code; at the
		// 2,000-cent option the sale takes more off.
		{name: "a code that wins on some options only", target: "/l/guide/SAVE10", wants: []string{
			`"discount_code":` + fixed150 + `,"sale_label":null,`,
			`"options":{"%[3]s":{"discount_code":` + fixed150 + `,"sale_label":null},"%[4]s":{"discount_code":` + saleResult + `,"sale_label":"Sale"}},`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				save10(t, conn, map[string]any{"amount_percentage": nil, "amount_cents": 150})
				sale(t, conn)
				testdb.Insert(t, conn, "variant_categories", map[string]any{"id": sizeCategory, "link_id": productID, "title": "Size"})
				for i, id := range []int64{small, large} {
					testdb.Insert(t, conn, "base_variants", map[string]any{"id": id, "type": "Variant", "variant_category_id": sizeCategory,
						"name": fmt.Sprint("Size ", i), "position_in_category": i, "price_difference_cents": i * 1500, "created_at": testNow, "updated_at": testNow})
				}
			}},
		// evaluate_for_buyer gives a signed-out visitor the tier that starts at no months of ownership.
		{name: "a tiered code", target: "/l/guide/SAVE10", wants: []string{quotes("SAVE10", valid("SAVE10", ""), "null")},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				save10(t, conn, map[string]any{"amount_percentage": nil,
					"ownership_duration_tiers": `[{"months":12,"amount_percentage":25},{"months":"0","amount_percentage":10.9}]`})
			}},
		// With no tier to start at, BestOfferCodeService reads a discount the computing service never set.
		{name: "a tiered code with no starting tier", target: "/l/guide/SAVE10", reason: "tiered offer code",
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				save10(t, conn, map[string]any{"amount_percentage": nil, "ownership_duration_tiers": `[{"months":12,"amount_percentage":25}]`})
			}},
		{name: "a limited code with uses left", target: "/l/guide/SAVE10", wants: []string{quotes("SAVE10", valid("SAVE10", ""), "null")},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				save10(t, conn, map[string]any{"max_purchase_count": 5})
				insertCodeUse(t, conn, 1_796_501, codeID, map[string]any{"quantity": 4})
			}},
		{name: "an ended code with no uses left", target: "/l/guide/SAVE10", wants: []string{quotes("SAVE10", invalid("inactive"), "null")},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				save10(t, conn, map[string]any{"max_purchase_count": 1, "expires_at": past})
				insertCodeUse(t, conn, 1_796_501, codeID, nil)
			}},
		{name: "a sold-out code", target: "/l/guide/SAVE10", wants: []string{quotes("SAVE10", invalid("sold_out"), "null")},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				save10(t, conn, map[string]any{"max_purchase_count": 2})
				insertCodeUse(t, conn, 1_796_501, codeID, map[string]any{"quantity": 2})
			}},
		// The quantity rises to the code's minimum, which the uses left must cover.
		{name: "a code with fewer uses left than its minimum", target: "/l/guide/SAVE10",
			wants: []string{quotes("SAVE10", invalid("insufficient_times_of_use"), "null")},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				save10(t, conn, map[string]any{"max_purchase_count": 5, "minimum_quantity": 3})
				insertCodeUse(t, conn, 1_796_501, codeID, map[string]any{"quantity": 3})
			}},
		// The computing service drops an option outside the code's scope before its buyer and usage checks.
		{name: "a code for some options", target: "/l/guide/SAVE10", wants: []string{
			`"discount_code":` + valid("SAVE10", smallOnly) + `,"sale_label":null,`,
			optionQuotes("SAVE10", valid("SAVE10", smallOnly), "null", invalid("option_not_eligible")),
		}, setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			save10(t, conn, nil)
			sizes(t, conn, codeID)
		}},
		{name: "a sold-out code for some options", target: "/l/guide/SAVE10", wants: []string{
			`"discount_code":` + invalid("sold_out") + `,`, optionQuotes("SAVE10", invalid("sold_out"), "null", invalid("option_not_eligible")),
		}, setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			save10(t, conn, map[string]any{"max_purchase_count": 1})
			insertCodeUse(t, conn, 1_796_501, codeID, nil)
			sizes(t, conn, codeID)
		}},
		// Outside the sale's scope the sold-out code's own scope decides.
		{name: "a sale and a sold-out code for the same option", target: "/l/guide/SAVE10", wants: []string{
			`"options":{"%[3]s":{"discount_code":{"valid":true,"code":"SALE20",`,
			`"sale_label":"Sale"},"%[4]s":{"discount_code":` + invalid("option_not_eligible") + `,"sale_label":null}},`,
		}, setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			sale(t, conn)
			sizes(t, conn, autoID)
			save10(t, conn, map[string]any{"max_purchase_count": 1})
			insertCodeUse(t, conn, 1_796_501, codeID, nil)
			testdb.Insert(t, conn, "offer_codes_variants", map[string]any{"id": int64(1_796_302), "offer_code_id": codeID, "variant_id": small})
		}},
		{name: "an existing customers' code for some options", target: "/l/guide/SAVE10", wants: []string{
			optionQuotes("SAVE10", invalid("not_existing_customer"), "null", invalid("option_not_eligible")),
		}, setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			save10(t, conn, map[string]any{"existing_customers_only": true})
			sizes(t, conn, codeID)
		}},
		// inactive comes before the scope.
		{name: "an expired code for some options", target: "/l/guide/SAVE10", wants: []string{
			optionQuotes("SAVE10", invalid("inactive"), "null", invalid("inactive")),
		}, setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			save10(t, conn, map[string]any{"expires_at": past})
			sizes(t, conn, codeID)
		}},
		// Outside the sale's scope, the unknown code's own result is left.
		{name: "a sale for some options over an unknown code", target: "/l/guide/NOPE", wants: []string{
			`"sale_label":"Sale",`, `"options":{"%[3]s":{"discount_code":{"valid":true,"code":"SALE20",`,
			`"sale_label":"Sale"},"%[4]s":{"discount_code":` + invalid("invalid_offer") + `,"sale_label":null}},`,
		}, setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			sale(t, conn)
			sizes(t, conn, autoID)
		}},
		// The collation matches the typed code to both rows, and both of Rails' lookups take SAVE10.
		{name: "two codes MySQL can't tell apart", target: "/l/guide/save10", wants: []string{`"discount_code":` + valid("save10", "") + `,"sale_label":null,`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				save10(t, conn, nil)
				insertOfferCode(t, conn, autoID, map[string]any{"code": "Save10", "amount_percentage": 5, "universal": true})
			}},
		// The computing service passes over a code for another product to the one that applies.
		{name: "another product's code first", target: "/l/guide/save10", wants: []string{`"discount_code":` + valid("save10", "") + `,"sale_label":null,`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				save10(t, conn, nil)
				insertOfferCode(t, conn, codeID-1, map[string]any{"code": "save10", "amount_percentage": 5})
				testdb.Insert(t, conn, "offer_codes_products", map[string]any{"id": int64(1_796_104), "offer_code_id": codeID - 1, "product_id": int64(1_796_999)})
			}},
		// Nothing by the string applies, so the computing service answers invalid_offer.
		{name: "no code by the string applying", target: "/l/guide/save10", wants: []string{`"discount_code":` + invalid("invalid_offer") + `,`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				save10(t, conn, map[string]any{"universal": false, "amount_percentage": nil, "amount_cents": 100, "currency_type": "eur"})
				testdb.Insert(t, conn, "offer_codes_products", map[string]any{"id": int64(1_796_105), "offer_code_id": codeID, "product_id": productID})
				insertOfferCode(t, conn, autoID, map[string]any{"code": "save10", "amount_percentage": 5})
				testdb.Insert(t, conn, "offer_codes_products", map[string]any{"id": int64(1_796_106), "offer_code_id": autoID, "product_id": int64(1_796_999)})
			}},
		{name: "another seller's code on this product", target: "/l/guide/save10", reason: "offer code lookup",
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				insertOfferCode(t, conn, codeID, map[string]any{"code": "SAVE10", "amount_percentage": 10, "user_id": int64(1)})
				testdb.Insert(t, conn, "offer_codes_products", map[string]any{"id": int64(1_796_107), "offer_code_id": codeID, "product_id": productID})
				insertOfferCode(t, conn, autoID, map[string]any{"code": "save10", "amount_percentage": 5})
				testdb.Insert(t, conn, "offer_codes_products", map[string]any{"id": int64(1_796_108), "offer_code_id": autoID, "product_id": int64(1_796_999)})
			}},
		// find_offer_code takes the product's code, and the computing service the universal one,
		// whose 10% the result shows.
		{name: "a product's code with a universal code's string", target: "/l/guide/save10",
			wants: []string{quotes("save10", valid("save10", ""), "null")},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				save10(t, conn, nil)
				insertOfferCode(t, conn, autoID, map[string]any{"code": "Save10", "amount_percentage": 5})
				testdb.Insert(t, conn, "offer_codes_products", map[string]any{"id": int64(1_796_103), "offer_code_id": autoID, "product_id": productID})
			}},
		// Weighed at the product's code's minimum, the universal one falls short of its own.
		{name: "a universal code by the string short of its own minimum", target: "/l/guide/save10",
			wants: []string{`"discount_code":` + invalid("unmet_minimum_purchase_quantity") + `,`,
				quotes("save10", invalid("unmet_minimum_purchase_quantity"), "null")},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				save10(t, conn, map[string]any{"minimum_quantity": 3})
				insertOfferCode(t, conn, autoID, map[string]any{"code": "Save10", "amount_percentage": 5})
				testdb.Insert(t, conn, "offer_codes_products", map[string]any{"id": int64(1_796_103), "offer_code_id": autoID, "product_id": productID})
			}},
		// The product's code's minimum of two raises the quantity the universal code is checked at:
		// its one use left falls short, and its once-per-cart amount covers two units.
		{name: "a universal code by the string with one use left", target: "/l/guide/save10",
			wants: []string{quotes("save10", invalid("insufficient_times_of_use"), "null")},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				save10(t, conn, map[string]any{"max_purchase_count": 1})
				insertOfferCode(t, conn, autoID, map[string]any{"code": "Save10", "amount_percentage": 5, "minimum_quantity": 2})
				testdb.Insert(t, conn, "offer_codes_products", map[string]any{"id": int64(1_796_103), "offer_code_id": autoID, "product_id": productID})
			}},
		{name: "a once-per-cart universal code by the string", target: "/l/guide/save10", wants: []string{`"discount_code":{"valid":true,"code":"save10",` +
			`"discount":{"type":"fixed","cents":600,"product_ids":null,"expires_at":null,"minimum_quantity":null,"duration_in_billing_cycles":null,` +
			`"minimum_amount_cents":null,"once_per_cart":true,"once_per_cart_id":"%[2]s","once_per_cart_amount_cents":600,` +
			`"once_per_cart_has_usage_limit":false}},`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				save10(t, conn, map[string]any{"amount_percentage": nil, "amount_cents": 600, "flags": offerCodeOncePerCart})
				insertOfferCode(t, conn, autoID, map[string]any{"code": "Save10", "amount_percentage": 5, "minimum_quantity": 2})
				testdb.Insert(t, conn, "offer_codes_products", map[string]any{"id": int64(1_796_103), "offer_code_id": autoID, "product_id": productID})
			}},
		// evaluate_code memoizes under the product's code's scope, which takes every option, so the
		// universal code's result for the first option, where it applies, is every option's.
		{name: "a scoped universal code by the string", target: "/l/guide/save10",
			wants: []string{`"discount_code":` + valid("save10", smallOnly) + `,`,
				optionQuotes("save10", valid("save10", smallOnly), "null", valid("save10", smallOnly))},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				save10(t, conn, nil)
				sizes(t, conn, codeID)
				insertOfferCode(t, conn, autoID, map[string]any{"code": "Save10", "amount_percentage": 5})
				testdb.Insert(t, conn, "offer_codes_products", map[string]any{"id": int64(1_796_103), "offer_code_id": autoID, "product_id": productID})
			}},
	} {
		t.Run(c.name, func(t *testing.T) {
			e := newTestEnv(t)
			if c.setup != nil {
				c.setup(t, e, testdb.Open(t))
			}
			body, hdr := e.renderAt(t, c.target, c.headers, c.reason)
			e.wantAll(t, body, c.wants, productID, codeID, small, large)
			if c.reason == "" && (hdr.Get("X-Robots-Tag") == "noindex") == c.indexed {
				t.Errorf("X-Robots-Tag %q", hdr.Get("X-Robots-Tag"))
			}
		})
	}
}

// check_if_needs_redirect keeps the code, and set_x_robots_tag_header has already run.
func TestAnOfferCodeRedirectKeepsItsCode(t *testing.T) {
	for target, want := range map[string]struct{ location, robots string }{
		"/l/gowebp1/SAVE10":  {"https://gowebproductseller.gumroad.com/l/guide/SAVE10", "noindex"},
		"/l/gowebp1?code=X1": {"https://gowebproductseller.gumroad.com/l/guide/X1?code=X1", "noindex"},
		"/l/gowebp1?code=":   {"https://gowebproductseller.gumroad.com/l/guide?code=", ""},
	} {
		t.Run(target, func(t *testing.T) {
			w := newTestEnv(t).get(host, target, nil)
			if w.Code != http.StatusMovedPermanently || w.Header().Get("Location") != want.location || w.Header().Get("X-Robots-Tag") != want.robots {
				t.Errorf("%d %q %q", w.Code, w.Header().Get("Location"), w.Header().Get("X-Robots-Tag"))
			}
		})
	}
}

// A call's page differs only by the calendar's preload; its availabilities load later. A
// commission's differs only in the local price Rails may withhold.
func TestCallsAndCommissions(t *testing.T) {
	const category = int64(1_797_001)
	call := func(conn *sql.DB) {
		conn.Exec("UPDATE links SET native_type = 'call', flags = flags | ? WHERE id = ?", productIsMultiseatLicense, productID)
	}
	for _, c := range []struct {
		name    string
		reason  string
		headers map[string]string
		setup   func(t *testing.T, e *testEnv, conn *sql.DB)
		check   func(t *testing.T, e *testEnv, body string)
	}{
		{name: "a call", setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			call(conn)
			testdb.Insert(t, conn, "variant_categories", map[string]any{"id": category, "link_id": productID, "title": "Duration"})
			for i, minutes := range []int{30, 60} {
				testdb.Insert(t, conn, "base_variants", map[string]any{"id": category + 1 + int64(i), "type": "Variant", "variant_category_id": category,
					"name": fmt.Sprint(minutes, " minutes"), "position_in_category": i, "duration_in_minutes": minutes, "created_at": testNow, "updated_at": testNow})
			}
		}, check: func(t *testing.T, e *testEnv, body string) {
			// set_product_page_meta adds it right before the canonical link.
			preload := `<link rel="modulepreload" crossorigin="anonymous" href="` + e.config.Page.CalendarHref + `" inertia="call-calendar">`
			if !strings.Contains(body, preload+"\n<link rel=\"canonical\"") {
				t.Errorf("no %s right before the canonical link", preload)
			}
			e.wantAll(t, body, []string{`"headKey":"call-calendar"`, `"duration_in_minutes":30}`, `"is_multiseat_license":false,`,
				`"eligible_for_installment_plans":true,`})
		}},
		{name: "a product that isn't a call", check: func(t *testing.T, e *testEnv, body string) {
			if strings.Contains(body, "call-calendar") {
				t.Error("a calendar preload")
			}
		}},
		{name: "a call without the calendar in the manifest", reason: "call calendar asset", setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			call(conn)
			e.config.Page.CalendarHref = ""
		}},
		{name: "a commission", check: func(t *testing.T, e *testEnv, body string) {
			e.wantAll(t, body, []string{`"native_type":"commission",`, `"eligible_for_installment_plans":false,`})
		}, setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			conn.Exec("UPDATE links SET native_type = 'commission' WHERE id = ?", productID)
		}},
		{name: "a commission with a local price", headers: eurCookie, check: func(t *testing.T, e *testEnv, body string) {
			e.wantAll(t, body, []string{`"buyer_currency_shown":"eur",`, `"native_type":"commission",`})
		}, setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			e.localEUR("0.92345")
			conn.Exec("UPDATE links SET native_type = 'commission' WHERE id = ?", productID)
		}},
	} {
		t.Run(c.name, func(t *testing.T) {
			e := newTestEnv(t)
			if c.setup != nil {
				c.setup(t, e, testdb.Open(t))
			}
			body := e.render(t, c.headers, c.reason)
			if c.check != nil {
				c.check(t, e, body)
			}
		})
	}
}

func TestInstallmentPlansPreordersAndWaitlists(t *testing.T) {
	plan := insertInstallmentPlan
	waitlist := func(conn *sql.DB, draft bool) {
		conn.Exec("UPDATE links SET flags = flags | ?, draft = ? WHERE id = ?", productWaitlistEnabled, draft, productID)
	}
	// waitlistPage is an unpublished product taking waitlist signups, with custom HTML.
	waitlistPage := func(t *testing.T, e *testEnv, conn *sql.DB, html string) {
		waitlist(conn, false)
		conn.Exec("UPDATE links SET purchase_disabled_at = ? WHERE id = ?", testNow, productID)
		e.redis.HSet("custom_html_pages", "boolean", "true")
		testdb.Insert(t, conn, "pages", map[string]any{"id": int64(1_793_201), "pageable_type": "Link", "pageable_id": productID,
			"custom_html": html, "created_at": testNow, "updated_at": testNow})
	}
	for _, c := range []struct {
		name    string
		wants   []string
		reason  string
		headers map[string]string
		setup   func(t *testing.T, e *testEnv, conn *sql.DB)
	}{
		{name: "an installment plan", wants: []string{`"eligible_for_installment_plans":true,"allow_installment_plan":true,` +
			`"installment_plan":{"number_of_installments":3,"recurrence":"monthly"},`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) { plan(t, conn, 1_793_001, "monthly", nil) }},
		{name: "a deleted installment plan", wants: []string{`"allow_installment_plan":false,"installment_plan":null,`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) { plan(t, conn, 1_793_001, "monthly", testNow) }},
		// The has_one's unordered statement takes the row MySQL's plan returns, here the lower id's.
		{name: "two installment plans", wants: []string{`"installment_plan":{"number_of_installments":3,"recurrence":"monthly"},`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				plan(t, conn, 1_793_001, "monthly", nil)
				plan(t, conn, 1_793_002, "weekly", nil)
			}},
		// The enum reads a value it doesn't map as nil.
		{name: "a recurrence the enum doesn't map", wants: []string{`"installment_plan":{"number_of_installments":3,"recurrence":null},`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) { plan(t, conn, 1_793_001, "weekly", nil) }},
		{name: "an installment plan with a local price", headers: eurCookie,
			wants: []string{`"buyer_currency_shown":"eur",`, `"installment_plan":{"number_of_installments":3,"recurrence":"monthly"},`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				e.localEUR("0.92345")
				plan(t, conn, 1_793_001, "monthly", nil)
			}},
		{name: "a preorder", wants: []string{`"eligible_for_installment_plans":false,`, `"preorder":{"release_date":"2026-12-01T10:00:00Z"},`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				preorder(t, conn, time.Date(2026, 12, 1, 10, 0, 0, 0, time.UTC))
			}},
		{name: "a preorder without a release date", wants: []string{`"preorder":{"release_date":null},`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) { preorder(t, conn, nil) }},
		{name: "a preorder without its link", reason: "preorder link", setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
			conn.Exec("UPDATE links SET flags = flags | ? WHERE id = ?", productIsInPreorderState, productID)
		}},
		{name: "a preorder with a local price", headers: eurCookie, wants: []string{`"buyer_currency_shown":"eur",`, `"preorder":{"release_date":null},`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				e.localEUR("0.92345")
				preorder(t, conn, nil)
			}},
		{name: "a waitlist on a draft", wants: []string{`"waitlist":{"recaptcha_site_key":null,"count":null},`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) { waitlist(conn, true) }},
		{name: "a waitlist from an unreviewed seller", wants: []string{`"waitlist":{"recaptcha_site_key":"site-key","count":null},`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				e.config.Page.RecaptchaSiteKey = "site-key"
				conn.Exec("UPDATE users SET user_risk_state = 'not_reviewed' WHERE id = ?", sellerID)
				waitlist(conn, true)
			}},
		{name: "a waitlist once published", wants: []string{`"waitlist":null,`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) { waitlist(conn, false) }},
		{name: "a waitlist with purchases disabled", wants: []string{`"waitlist":{"recaptcha_site_key":null,"count":null},`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				waitlist(conn, false)
				conn.Exec("UPDATE links SET purchase_disabled_at = ? WHERE id = ?", testNow, productID)
			}},
		{name: "a waitlist taken down by an admin", wants: []string{`"waitlist":null,`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				waitlist(conn, true)
				conn.Exec("UPDATE links SET flags = flags | ? WHERE id = ?", productUnpublishedByAdmin, productID)
			}},
		// Rails shows the custom page only when it holds the waitlist form.
		{name: "a waitlist with custom HTML", wants: []string{`"waitlist":{"recaptcha_site_key":null,"count":null},`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) { waitlistPage(t, e, conn, "<form data-waitlist></form>") }},
		{name: "a waitlist whose custom HTML holds the form", wants: []string{"data-gumroad-waitlist-wrapper", `var PRODUCT_ID = "`},
			setup: func(t *testing.T, e *testEnv, conn *sql.DB) {
				waitlistPage(t, e, conn, `<form data-gumroad-waitlist><input name="email"></form>`)
			}},
	} {
		t.Run(c.name, func(t *testing.T) {
			e := newTestEnv(t)
			c.setup(t, e, testdb.Open(t))
			body := e.render(t, c.headers, c.reason)
			for _, want := range c.wants {
				if !strings.Contains(body, want) {
					t.Errorf("want %s", want)
				}
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
	platform := insertPlatformAccount
	own := func(t *testing.T, conn *sql.DB, country, jsonData string) {
		testdb.Insert(t, conn, "merchant_accounts", map[string]any{"id": int64(1_790_902), "user_id": sellerID, "charge_processor_id": "stripe",
			"country": country, "currency": "usd", "json_data": jsonData, "charge_processor_alive_at": testNow, "created_at": testNow,
			"updated_at": testNow})
	}
	charging := func(e *testEnv) { e.redis.HSet("buyer_currency_charging", "boolean", "true") }
	linked := func(conn *sql.DB) {
		conn.Exec("UPDATE users SET flags = flags | ? WHERE id = ?", userCheckMerchantAccountIsLinked, sellerID)
	}
	// migrating is a seller with merchant migration on and the compliance info given, if any,
	// whose unlinked Connect account's fresh marker keeps its own quote, beside the platform's.
	migrating := func(t *testing.T, e *testEnv, conn *sql.DB, info map[string]any) {
		charging(e)
		e.redis.HSet("merchant_migration", "boolean", "true")
		platform(t, conn, "usd", `{}`)
		own(t, conn, "US", `{"meta":{"stripe_connect":"true"},"settlement_currency_mismatch_map":{"eur":"2026-11-06T06:00:00Z"}}`)
		if info != nil {
			info["id"], info["user_id"], info["created_at"], info["updated_at"] = int64(1_799_961), sellerID, testNow, testNow
			testdb.Insert(t, conn, "user_compliance_info", info)
		}
	}
	brlLocal := display("brl", "usd", "2716", "5.4321", "buyer_local") + `,"buyer_currency":"brl","buyer_local_currency_rate":5.4321,` +
		`"buyer_local_currency_subunit_to_unit":100,"buyer_local_price_cents":2716,"rental_price_cents":`
	// shape makes the product's flags and native type, charged on the platform account.
	shape := func(t *testing.T, e *testEnv, conn *sql.DB, flags int64, nativeType string) {
		charging(e)
		platform(t, conn, "usd", `{}`)
		conn.Exec("UPDATE links SET flags = flags | ?, native_type = ? WHERE id = ?", flags, nativeType, productID)
	}
	membership := func(t *testing.T, e *testEnv, conn *sql.DB, flags int64) {
		shape(t, e, conn, productIsRecurringBilling|flags, "membership")
		conn.Exec("UPDATE links SET subscription_duration = 0 WHERE id = ?", productID)
		conn.Exec("UPDATE prices SET recurrence = 'monthly' WHERE id = ?", priceID)
	}
	ramp := func(e *testEnv) { e.redis.HSet("buyer_currency_subscriptions", "boolean", "true") }
	mandate := func(e *testEnv) { e.redis.HSet("india_card_mandate_reliability", "boolean", "true") }
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
		// merchant_migration_enabled? through the linked flag routes charges to the Connect account,
		// which settles its own quote.
		{"a linked Connect account holding USD", "usd", "EUR", eurLocal, "", func(t *testing.T, e *testEnv, conn *sql.DB) {
			charging(e)
			linked(conn)
			own(t, conn, "US", `{"meta":{"stripe_connect":"true"}}`)
		}},
		{"a linked Connect account holding BRL", "usd", "EUR", usdDefault, "", func(t *testing.T, e *testEnv, conn *sql.DB) {
			charging(e)
			linked(conn)
			own(t, conn, "BR", `{"meta":{"stripe_connect":"true"}}`)
			conn.Exec("UPDATE merchant_accounts SET currency = 'brl' WHERE id = 1790902")
		}},
		{"a Connect account's own blanket marker", "usd", "EUR", usdDefault, "", func(t *testing.T, e *testEnv, conn *sql.DB) {
			charging(e)
			linked(conn)
			own(t, conn, "US", `{"meta":{"stripe_connect":"true"},"settlement_currency_mismatch_noticed_at":"2026-11-06T06:00:00Z"}`)
		}},
		{"a Connect account's fresh marker for the currency", "usd", "EUR", usdDefault, "", func(t *testing.T, e *testEnv, conn *sql.DB) {
			charging(e)
			linked(conn)
			own(t, conn, "US", `{"meta":{"stripe_connect":"true"},"settlement_currency_mismatch_map":{"eur":"2026-11-06T06:00:00Z"}}`)
		}},
		// The linked Connect account wins over the seller's own Custom account, whose destination
		// charges would need their flag.
		{"a linked Connect account beside the seller's own", "usd", "EUR", eurLocal, "", func(t *testing.T, e *testEnv, conn *sql.DB) {
			charging(e)
			linked(conn)
			own(t, conn, "US", `{}`)
			testdb.Insert(t, conn, "merchant_accounts", map[string]any{"id": int64(1_790_903), "user_id": sellerID, "charge_processor_id": "stripe",
				"country": "US", "currency": "usd", "json_data": `{"meta":{"stripe_connect":"true"}}`, "charge_processor_alive_at": testNow,
				"created_at": testNow, "updated_at": testNow})
		}},
		// Without the linked flag, merchant_migration_enabled? is the feature and a compliance
		// country Stripe Connect supports.
		{"a Connect account routed by compliance country", "usd", "EUR", usdDefault, "", func(t *testing.T, e *testEnv, conn *sql.DB) {
			migrating(t, e, conn, map[string]any{"country": "United States"})
		}},
		{"a compliance country Stripe Connect doesn't take", "usd", "EUR", eurLocal, "", func(t *testing.T, e *testEnv, conn *sql.DB) {
			migrating(t, e, conn, map[string]any{"country": "India"})
		}},
		{"merchant migration without compliance info", "usd", "EUR", eurLocal, "", func(t *testing.T, e *testEnv, conn *sql.DB) {
			migrating(t, e, conn, nil)
		}},
		{"a business routed by its legal entity's country", "usd", "EUR", usdDefault, "", func(t *testing.T, e *testEnv, conn *sql.DB) {
			e.redis.HSet("stripe_connect_routing_by_legal_entity_country", "boolean", "true")
			migrating(t, e, conn, map[string]any{"country": "India", "business_country": "United Kingdom", "is_business": true})
		}},
		{"a business routed by its individual country", "usd", "EUR", eurLocal, "", func(t *testing.T, e *testEnv, conn *sql.DB) {
			migrating(t, e, conn, map[string]any{"country": "India", "business_country": "United Kingdom", "is_business": true})
		}},
		// Without merchant migration the Connect account, and its marker, are skipped for the platform's.
		{"an unlinked Connect account without merchant migration", "usd", "EUR", eurLocal, "", func(t *testing.T, e *testEnv, conn *sql.DB) {
			charging(e)
			platform(t, conn, "usd", `{}`)
			own(t, conn, "US", `{"meta":{"stripe_connect":"true"},"settlement_currency_mismatch_map":{"eur":"2026-11-06T06:00:00Z"}}`)
		}},
		{"a membership outside the subscription ramp", "usd", "EUR", usdDefault, "", func(t *testing.T, e *testEnv, conn *sql.DB) {
			membership(t, e, conn, 0)
		}},
		{"a membership in the subscription ramp", "usd", "EUR", eurLocal, "", func(t *testing.T, e *testEnv, conn *sql.DB) {
			membership(t, e, conn, 0)
			ramp(e)
		}},
		{"a free trial in the subscription ramp", "usd", "EUR", usdDefault, "", func(t *testing.T, e *testEnv, conn *sql.DB) {
			membership(t, e, conn, productFreeTrialEnabled)
			conn.Exec("UPDATE links SET free_trial_duration_unit = 0, free_trial_duration_amount = 1 WHERE id = ?", productID)
			ramp(e)
		}},
		{"a commission outside the subscription ramp", "usd", "EUR", usdDefault, "", func(t *testing.T, e *testEnv, conn *sql.DB) {
			shape(t, e, conn, 0, "commission")
		}},
		{"a commission in the subscription ramp", "usd", "EUR", eurLocal, "", func(t *testing.T, e *testEnv, conn *sql.DB) {
			shape(t, e, conn, 0, "commission")
			ramp(e)
		}},
		{"a preorder outside the subscription ramp", "usd", "EUR", usdDefault, "", func(t *testing.T, e *testEnv, conn *sql.DB) {
			shape(t, e, conn, 0, "digital")
			preorder(t, conn, nil)
		}},
		{"an installment plan outside the subscription ramp", "usd", "EUR", usdDefault, "", func(t *testing.T, e *testEnv, conn *sql.DB) {
			shape(t, e, conn, 0, "digital")
			insertInstallmentPlan(t, conn, 1_790_921, "monthly", nil)
		}},
		// Stripe's India mandate list has euros but not reais.
		{"a membership in a currency the mandate takes", "usd", "EUR", eurLocal, "", func(t *testing.T, e *testEnv, conn *sql.DB) {
			membership(t, e, conn, 0)
			ramp(e)
			mandate(e)
		}},
		{"a membership in a currency the mandate doesn't take", "usd", "BRL", usdDefault, "", func(t *testing.T, e *testEnv, conn *sql.DB) {
			membership(t, e, conn, 0)
			ramp(e)
			mandate(e)
		}},
		{"a one-time product in that currency", "usd", "BRL", brlLocal, "", func(t *testing.T, e *testEnv, conn *sql.DB) {
			shape(t, e, conn, 0, "digital")
			mandate(e)
		}},
		{"a membership in that currency without the mandate flag", "usd", "BRL", brlLocal, "", func(t *testing.T, e *testEnv, conn *sql.DB) {
			membership(t, e, conn, 0)
			ramp(e)
		}},
		// A Connect account charges directly, which the mandate doesn't constrain.
		{"a membership in that currency through a Connect account", "usd", "BRL", brlLocal, "", func(t *testing.T, e *testEnv, conn *sql.DB) {
			membership(t, e, conn, 0)
			ramp(e)
			mandate(e)
			linked(conn)
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
		// The json gem's Grisu2 writes this Float with more digits than Float#to_s.
		{"a rate JSON writes long", "usd", "AUD",
			display("aud", "usd", "728", "1.4568160000000001", "buyer_local") + `,"buyer_currency":"aud",` +
				`"buyer_local_currency_rate":1.4568160000000001,"buyer_local_currency_subunit_to_unit":100,"buyer_local_price_cents":728,"rental_price_cents":`,
			"", func(t *testing.T, e *testEnv, conn *sql.DB) { e.redis.Set("currencies:AUD", "1.456816") }},
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
			e.redis.Set("currencies:BRL", "5.4321")
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

func TestVariantsRenderAsOptions(t *testing.T) {
	const size, color = int64(1_791_001), int64(1_791_002)
	const small, large, red = int64(1_791_101), int64(1_791_102), int64(1_791_103)
	const sku1, sku2, defaultSku, deletedSku = int64(1_791_501), int64(1_791_502), int64(1_791_503), int64(1_791_504)
	sku := func(id int64, name any, flags int, deletedAt any, maxPurchases, diff any) map[string]any {
		return map[string]any{"id": id, "type": "Sku", "link_id": productID, "name": name, "flags": flags, "deleted_at": deletedAt,
			"max_purchase_count": maxPurchases, "sales_count_for_inventory_cache": 2, "price_difference_cents": diff,
			"customizable_price": 1, "created_at": testNow, "updated_at": testNow}
	}
	physical := func(conn *sql.DB, flags int64) {
		conn.Exec("UPDATE links SET flags = flags | ?, native_type = 'physical', require_shipping = 1 WHERE id = ?", flags, productID)
	}
	// Rails leaves a Variant's link_id NULL; it belongs through its category.
	variant := func(id, category int64, name string, position, maxPurchases, sold, diff any) map[string]any {
		if sold == nil {
			sold = 0
		}
		return map[string]any{"id": id, "type": "Variant", "variant_category_id": category, "name": name,
			"position_in_category": position, "max_purchase_count": maxPurchases, "sales_count_for_inventory_cache": sold,
			"price_difference_cents": diff, "created_at": testNow, "updated_at": testNow}
	}
	file := func(t *testing.T, conn *sql.DB, id int64, variantID int64) {
		testdb.Insert(t, conn, "product_files", map[string]any{"id": id, "link_id": productID, "filetype": "pdf", "size": 2048,
			"url": "https://s3.amazonaws.com/gumroad/attachments/x/y/original/a.pdf", "created_at": testNow, "updated_at": testNow})
		if variantID != 0 {
			testdb.Insert(t, conn, "base_variants_product_files", map[string]any{"id": id - 1_791_200 + 1_791_300, "base_variant_id": variantID,
				"product_file_id": id})
		}
	}
	const pdf = `{"formats":["PDF"],"total_size":2048,"count":1}`
	for _, c := range []struct {
		name   string
		wants  []string
		reason string
		setup  func(t *testing.T, conn *sql.DB)
	}{
		{"options in position order, and the lowest difference in the offer", []string{`"options":[` +
			`{"id":"%[2]s","name":"Guide \u003c1\u003e","quantity_left":null,"description":"","price_difference_cents":300,"recurrence_price_values":null,"is_pwyw":false,"duration_in_minutes":null},` +
			`{"id":"%[1]s","name":"Small","quantity_left":2,"description":"","price_difference_cents":100,"recurrence_price_values":null,"is_pwyw":false,"duration_in_minutes":null}]`,
			`"url":"https://gowebproductseller.gumroad.com/l/guide","price":6.0}`},
			"", func(t *testing.T, conn *sql.DB) {
				testdb.Insert(t, conn, "base_variants", variant(small, size, "Small", 1, 3, 1, 100))
				testdb.Insert(t, conn, "base_variants", variant(large, size, "Untitled", 0, nil, nil, 300))
			}},
		{"options from the first category only", []string{`"options":[{"id":"%[1]s","name":"Small",`}, "", func(t *testing.T, conn *sql.DB) {
			testdb.Insert(t, conn, "variant_categories", map[string]any{"id": color, "link_id": productID, "title": "Color"})
			testdb.Insert(t, conn, "base_variants", variant(red, color, "Red", 0, nil, nil, 0))
			testdb.Insert(t, conn, "base_variants", variant(small, size, "Small", 0, nil, nil, 0))
		}},
		{"every option sold out", []string{`"quantity_remaining":0,`}, "", func(t *testing.T, conn *sql.DB) {
			testdb.Insert(t, conn, "base_variants", variant(small, size, "Small", 0, 1, 1, 0))
		}},
		{"another category still available", []string{`"quantity_remaining":null,`}, "", func(t *testing.T, conn *sql.DB) {
			testdb.Insert(t, conn, "variant_categories", map[string]any{"id": color, "link_id": productID, "title": "Color"})
			testdb.Insert(t, conn, "base_variants", variant(small, size, "Small", 0, 1, 1, 0))
			testdb.Insert(t, conn, "base_variants", variant(red, color, "Red", 0, 2, 1, 0))
		}},
		{"a pay-what-you-want default with no price difference", []string{`"pwyw":{"suggested_price_cents":null,"default_price_cents":0}`}, "",
			func(t *testing.T, conn *sql.DB) {
				conn.Exec("UPDATE links SET customizable_price = 1, price_cents = 0 WHERE id = ?", productID)
				conn.Exec("UPDATE prices SET price_cents = 0 WHERE id = ?", priceID)
				testdb.Insert(t, conn, "base_variants", variant(small, size, "Small", 0, nil, nil, 0))
			}},
		{"no pay-what-you-want default past a price difference", []string{`"pwyw":{"suggested_price_cents":null,"default_price_cents":null}`}, "",
			func(t *testing.T, conn *sql.DB) {
				conn.Exec("UPDATE links SET customizable_price = 1, price_cents = 0 WHERE id = ?", productID)
				conn.Exec("UPDATE prices SET price_cents = 0 WHERE id = ?", priceID)
				testdb.Insert(t, conn, "base_variants", variant(small, size, "Small", 0, nil, nil, 100))
			}},
		{"per-option files", []string{`"file_summaries":{"product":null,"options":{"%[1]s":` + pdf + `}}`}, "", func(t *testing.T, conn *sql.DB) {
			testdb.Insert(t, conn, "base_variants", variant(small, size, "Small", 0, nil, nil, 0))
			testdb.Insert(t, conn, "base_variants", variant(large, size, "Large", 1, nil, nil, 0))
			file(t, conn, 1_791_201, small)
			file(t, conn, 1_791_202, 0)
		}},
		// upcase leaves a character without case as it is.
		{"a file type ending in a quote", []string{`"file_summaries":{"product":null,"options":{"%[1]s":{"formats":["PDF”"],`}, "",
			func(t *testing.T, conn *sql.DB) {
				testdb.Insert(t, conn, "base_variants", variant(small, size, "Small", 0, nil, nil, 0))
				file(t, conn, 1_791_201, small)
				conn.Exec("UPDATE product_files SET filetype = 'pdf”' WHERE id = ?", 1_791_201)
			}},
		{"files shared by every option", []string{`"file_summaries":{"product":` + pdf + `,"options":{"%[1]s":` + pdf + `,"%[2]s":` + pdf + `}}`}, "",
			func(t *testing.T, conn *sql.DB) {
				conn.Exec("UPDATE links SET flags = flags | ? WHERE id = ?", productSameRichContentForAllVariants, productID)
				testdb.Insert(t, conn, "base_variants", variant(small, size, "Small", 0, nil, nil, 0))
				testdb.Insert(t, conn, "base_variants", variant(large, size, "Large", 1, nil, nil, 0))
				file(t, conn, 1_791_201, 0)
			}},
		{"hidden option pages recovered", []string{`"file_summaries":{"product":null,"options":{"%[1]s":` + pdf + `}}`}, "",
			func(t *testing.T, conn *sql.DB) {
				conn.Exec("UPDATE links SET flags = flags | ? WHERE id = ?", productSameRichContentForAllVariants, productID)
				testdb.Insert(t, conn, "base_variants", variant(small, size, "Small", 0, nil, nil, 0))
				testdb.Insert(t, conn, "rich_contents", map[string]any{"id": int64(1_791_401), "entity_type": "BaseVariant", "entity_id": small,
					"title": "Chapter one", "description": `[]`, "position": 0, "created_at": testNow, "updated_at": testNow})
				file(t, conn, 1_791_201, small)
				file(t, conn, 1_791_202, 0)
			}},
		// The title matches Tier under the collation, and a lone tier's inventory is the product's.
		{"a tier category", []string{`"quantity_remaining":2,`}, "", func(t *testing.T, conn *sql.DB) {
			conn.Exec("UPDATE variant_categories SET title = 'tier ' WHERE id = ?", size)
			testdb.Insert(t, conn, "base_variants", variant(small, size, "Small", 0, 3, 1, 0))
		}},
		{"a physical product's options, without file summaries", []string{`"is_physical":true,`, `"native_type":"physical",`,
			`"options":[{"id":"%[1]s","name":"Small",`, `"file_summaries":{"product":null,"options":{}}`},
			"", func(t *testing.T, conn *sql.DB) {
				physical(conn, productIsPhysical)
				testdb.Insert(t, conn, "base_variants", variant(small, size, "Small", 0, nil, nil, 0))
				file(t, conn, 1_791_201, small)
			}},
		// The SKUs' names stay raw, and they're never pay what you want; the Variants' order is moot.
		{"a physical product's SKUs, in id order, without the default or deleted ones", []string{`"options":[` +
			`{"id":"%[3]s","name":null,"quantity_left":3,"description":"","price_difference_cents":200,"recurrence_price_values":null,"is_pwyw":false,"duration_in_minutes":null},` +
			`{"id":"%[4]s","name":"Untitled","quantity_left":null,"description":"","price_difference_cents":0,"recurrence_price_values":null,"is_pwyw":false,"duration_in_minutes":null}]`,
			`"quantity_remaining":0,`},
			"", func(t *testing.T, conn *sql.DB) {
				// Sold-out Variants still make the product sold out; the SKUs' stock doesn't count.
				physical(conn, productIsPhysical|productSkusEnabled)
				testdb.Insert(t, conn, "base_variants", variant(small, size, "Small", nil, 1, 1, 0))
				testdb.Insert(t, conn, "base_variants", variant(large, size, "Large", nil, 1, 1, 0))
				testdb.Insert(t, conn, "base_variants", sku(sku2, "Untitled", 0, nil, nil, 0))
				testdb.Insert(t, conn, "base_variants", sku(sku1, nil, 0, nil, 5, 200))
				testdb.Insert(t, conn, "base_variants", sku(defaultSku, "Default", 1, nil, nil, 0))
				testdb.Insert(t, conn, "base_variants", sku(deletedSku, "Gone", 0, testNow, nil, 0))
			}},
		// A digital product's SKUs are its options, each summarizing its own files.
		{"a digital product's SKUs", []string{`"options":[{"id":"%[3]s","name":null,`,
			`"file_summaries":{"product":null,"options":{"%[3]s":` + pdf + `}}`}, "", func(t *testing.T, conn *sql.DB) {
			conn.Exec("UPDATE links SET flags = flags | ? WHERE id = ?", productSkusEnabled, productID)
			testdb.Insert(t, conn, "base_variants", variant(small, size, "Small", 0, nil, nil, 0))
			testdb.Insert(t, conn, "base_variants", sku(sku1, nil, 0, nil, nil, 0))
			testdb.Insert(t, conn, "base_variants", sku(sku2, "Untitled", 0, nil, nil, 0))
			file(t, conn, 1_791_201, sku1)
		}},
	} {
		t.Run(c.name, func(t *testing.T) {
			e := newTestEnv(t)
			conn := testdb.Open(t)
			testdb.Insert(t, conn, "variant_categories", map[string]any{"id": size, "link_id": productID, "title": "Size"})
			c.setup(t, conn)
			var headers map[string]string
			if c.reason != "" {
				headers = e.dryRun(host, "/l/guide", testNow)
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
			body := w.Body.String()
			page := html.UnescapeString(dataPage.FindStringSubmatch(body)[1])
			for _, want := range c.wants {
				if strings.Contains(want, "%[") {
					want = fmt.Sprintf(want, e.ids.Encrypt(small), e.ids.Encrypt(large), e.ids.Encrypt(sku1), e.ids.Encrypt(sku2))
				}
				if !strings.Contains(page, want) && !strings.Contains(body, want) {
					t.Errorf("want %s", want)
				}
			}
		})
	}
}

// in_order sets no tiebreak, so tied options come in the order MySQL returns Rails' own statement.
func TestTiedOptionsTakeTheOrderOfRailsStatement(t *testing.T) {
	const size = int64(1_791_001)
	e := newTestEnv(t)
	conn := testdb.Open(t)
	testdb.Insert(t, conn, "variant_categories", map[string]any{"id": size, "link_id": productID, "title": "Size"})
	for i, id := range []int64{1_791_103, 1_791_101, 1_791_102} {
		testdb.Insert(t, conn, "base_variants", map[string]any{"id": id, "type": "Variant", "variant_category_id": size,
			"name": fmt.Sprint("Option ", i), "sales_count_for_inventory_cache": 0, "created_at": testNow, "updated_at": testNow})
	}
	var want []int64
	err := scanNamed(t.Context(), conn, func(cols map[string]any) func() {
		var id int64
		cols["id"] = &id
		return func() { want = append(want, id) }
	}, optionRecordsStatement, productID, size)
	if err != nil {
		t.Fatal(err)
	}
	// Whatever order the options arrive in, they leave in the statement's.
	options := []*variantOption{{id: want[2]}, {id: want[1]}, {id: want[0]}}
	if err := (&handler{c: e.config}).orderTiedOptions(t.Context(), productID, size, options); err != nil {
		t.Fatal(err)
	}
	got := []int64{options[0].id, options[1].id, options[2].id}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("options %v, want %v", got, want)
	}
	// And the page renders them, rather than leaving it to Rails.
	w := e.get(host, "/l/guide", nil)
	if w.Code != http.StatusOK || e.railsHit != nil {
		t.Fatalf("%d %q, Rails hit: %v", w.Code, w.Header().Get("X-Go-Web-Fallback"), e.railsHit != nil)
	}
	rendered := pageProps(t, w.Body.String())["product"].(map[string]any)["options"].([]any)
	for i, o := range rendered {
		if o.(map[string]any)["id"] != e.ids.Encrypt(want[i]) {
			t.Errorf("rendered option %d is %v", i, o.(map[string]any)["id"])
		}
	}
}

// sales_count comes from Rails.cache, else Elasticsearch, written back for a minute.
func TestTheSalesCount(t *testing.T) {
	const latestPurchase = int64(1_791_501)
	// PurchaseSearchService's body for Purchase::ACTIVE_SALES_SEARCH_OPTIONS, as production builds it.
	wantBody := fmt.Sprintf(`{"query":{"bool":{"filter":[{"terms":{"product_id":[%d]}},{"term":{"not_refunded_except_subscriptions":true}},`+
		`{"term":{"not_chargedback_or_chargedback_reversed":true}},{"term":{"not_subscription_or_original_subscription_purchase":true}},`+
		`{"terms":{"purchase_state":["preorder_authorization_successful","successful","not_charged"]}}],"must_not":[{"exists":{"field":"subscription_deactivated_at"}},`+
		`{"term":{"selected_flags":"is_bundle_product_purchase"}},{"term":{"selected_flags":"is_commission_completion_purchase"}}]}},`+
		`"from":0,"size":0,"_source":false,"aggs":{},"track_total_hits":true}`, productID)
	var want any
	if err := json.Unmarshal([]byte(wantBody), &want); err != nil {
		t.Fatal(err)
	}
	var searches int
	search := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		searches++
		var got any
		body, _ := io.ReadAll(r.Body)
		if json.Unmarshal(body, &got) != nil || r.URL.Path != "/purchases/_search" || !reflect.DeepEqual(got, want) {
			t.Errorf("search %s %s", r.URL.Path, body)
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		io.WriteString(w, `{"hits":{"total":{"value":17,"relation":"eq"},"hits":[]}}`)
	}))
	defer search.Close()
	failing := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		searches++
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer failing.Close()
	price := int64(500)
	key := salesCountKey(productID, &price, sql.NullInt64{Int64: latestPurchase, Valid: true})
	for _, c := range []struct {
		name, reason string
		server       *httptest.Server
		cached       any
		readErr      error
		want         string
		searched     int
	}{
		{"counted and cached", "", search, nil, nil, `"sales_count":17,`, 1},
		{"read from the cache", "", search, int64(9), nil, `"sales_count":9,`, 0},
		{"a cached value this port can't read", "cached sales count", search, "9", nil, "", 0},
		{"the cache down", "cache", search, nil, railscache.ErrServerDown, "", 0},
		{"a failed search", "sales count search", failing, nil, nil, "", 1},
		{"no search client", "sales count", nil, nil, nil, "", 0},
	} {
		t.Run(c.name, func(t *testing.T) {
			searches = 0
			e := newTestEnv(t)
			conn := testdb.Open(t)
			conn.Exec("UPDATE links SET flags = flags | ? WHERE id = ?", productShouldShowSalesCount, productID)
			testdb.Insert(t, conn, "purchases", map[string]any{"id": latestPurchase, "link_id": productID, "created_at": testNow})
			if c.server != nil {
				client, err := elastic.NewWithClient(c.server.URL, c.server.Client())
				if err != nil {
					t.Fatal(err)
				}
				e.config.Page.Search = client
			}
			if c.cached != nil {
				e.cache.values[key] = c.cached
			}
			e.cache.readErr = c.readErr
			var headers map[string]string
			if c.reason != "" {
				headers = e.dryRun(host, "/l/guide", testNow)
			}
			w := e.get(host, "/l/guide", headers)
			if searches != c.searched {
				t.Errorf("%d searches, want %d", searches, c.searched)
			}
			if c.reason != "" {
				if w.Code != http.StatusNoContent || w.Header().Get("X-Go-Web-Fallback") != c.reason {
					t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
				}
				return
			}
			if w.Code != http.StatusOK {
				t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
			}
			if page := html.UnescapeString(dataPage.FindStringSubmatch(w.Body.String())[1]); !strings.Contains(page, c.want) {
				t.Errorf("want %s", c.want)
			}
			if wrote := slices.Contains(e.cache.writes, key); wrote != (c.searched > 0) || wrote && e.cache.ttls[key] != time.Minute {
				t.Errorf("cache writes %v, ttl %v", e.cache.writes, e.cache.ttls[key])
			}
		})
	}
}

func TestACollaboratorShowsAsCoCreator(t *testing.T) {
	const collabID, affiliateID, otherID = int64(1_790_002), int64(1_792_001), int64(1_792_002)
	affiliate := func(t *testing.T, conn *sql.DB, id int64, kind string, flags, linkFlags int64, deletedAt any) {
		testdb.Insert(t, conn, "affiliates", map[string]any{"id": id, "seller_id": sellerID, "affiliate_user_id": collabID,
			"affiliate_basis_points": 1000, "type": kind, "flags": flags, "deleted_at": deletedAt, "created_at": testNow, "updated_at": testNow})
		testdb.Insert(t, conn, "affiliates_links", map[string]any{"id": id, "affiliate_id": id, "link_id": productID,
			"affiliate_basis_points": 1000, "flags": linkFlags, "created_at": testNow, "updated_at": testNow})
	}
	// Flags are has_flags bits: Affiliate 1 apply_to_all_products and 3 dont_show_as_co_creator,
	// ProductAffiliate 1 dont_show_as_co_creator.
	collaborator := func(t *testing.T, conn *sql.DB, id, flags, linkFlags int64) {
		affiliate(t, conn, id, "Collaborator", flags, linkFlags, nil)
	}
	byline := `"collaborating_user":{"id":"1790002","name":"Collab","avatar_url":"%s","profile_url":"https://collab-user.gumroad.com","is_verified":true}`
	none := `"collaborating_user":null`
	for _, c := range []struct {
		name, want, reason string
		setup              func(t *testing.T, conn *sql.DB)
	}{
		{"confirmed", byline, "", func(t *testing.T, conn *sql.DB) { collaborator(t, conn, affiliateID, 0, 0) }},
		{"invitation pending", none, "", func(t *testing.T, conn *sql.DB) {
			collaborator(t, conn, affiliateID, 0, 0)
			testdb.Insert(t, conn, "collaborator_invitations", map[string]any{"id": int64(1_792_101), "collaborator_id": affiliateID,
				"created_at": testNow, "updated_at": testNow})
		}},
		{"hidden on this product", none, "", func(t *testing.T, conn *sql.DB) { collaborator(t, conn, affiliateID, 0, 1) }},
		{"hidden on every product", none, "", func(t *testing.T, conn *sql.DB) { collaborator(t, conn, affiliateID, 1|4, 0) }},
		{"every product's setting overrides this one's", byline, "", func(t *testing.T, conn *sql.DB) {
			collaborator(t, conn, affiliateID, 1, 1)
		}},
		{"hiding without every product is ignored", byline, "", func(t *testing.T, conn *sql.DB) {
			collaborator(t, conn, affiliateID, 4, 0)
		}},
		{"deleted", none, "", func(t *testing.T, conn *sql.DB) {
			affiliate(t, conn, affiliateID, "Collaborator", 0, 0, testNow)
		}},
		{"a direct affiliate", none, "", func(t *testing.T, conn *sql.DB) {
			affiliate(t, conn, affiliateID, "DirectAffiliate", 0, 0, nil)
		}},
		// take's unordered statement returns the lower id's row, which shows; the other doesn't.
		{"two collaborators", byline, "", func(t *testing.T, conn *sql.DB) {
			collaborator(t, conn, affiliateID, 0, 0)
			collaborator(t, conn, otherID, 0, 1)
		}},
		// The collaborator's own avatar, served as uploaded until it's resized.
		{"the collaborator's avatar", fmt.Sprintf(byline, "https://gumroad-public-storage.s3.amazonaws.com/avatars/collab"), "", func(t *testing.T, conn *sql.DB) {
			collaborator(t, conn, affiliateID, 0, 0)
			testdb.Insert(t, conn, "active_storage_blobs", map[string]any{"id": int64(1_792_201), "key": "avatars/collab", "filename": "a.png",
				"content_type": "image/png", "service_name": "amazon_public", "byte_size": 1, "created_at": testNow})
			testdb.Insert(t, conn, "active_storage_attachments", map[string]any{"id": int64(1_792_301), "name": "avatar", "record_type": "User",
				"record_id": collabID, "blob_id": int64(1_792_201), "created_at": testNow})
		}},
	} {
		t.Run(c.name, func(t *testing.T) {
			e := newTestEnv(t)
			jobs := sidekiqJobs(t, e)
			conn := testdb.Open(t)
			testdb.User(t, conn, collabID, map[string]any{"username": "collab_user", "external_id": "1790002", "name": "Collab", "verified": true})
			c.setup(t, conn)
			var headers map[string]string
			if c.reason != "" {
				headers = e.dryRun(host, "/l/guide", testNow)
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
			body := w.Body.String()
			// A user without an avatar gets the same default the seller's byline shows.
			avatar := pageProps(t, body)["product"].(map[string]any)["seller"].(map[string]any)["avatar_url"].(string)
			want := c.want
			if strings.Contains(want, "%s") {
				want = fmt.Sprintf(want, avatar)
			}
			page := html.UnescapeString(dataPage.FindStringSubmatch(body)[1])
			if !strings.Contains(page, want) {
				i := strings.Index(page, `"collaborating_user"`)
				t.Errorf("want %s, got %s", want, page[i:min(i+260, len(page))])
			}
			// Only the collaborator's unresized avatar is queued.
			queued, _ := jobs.List("queue:low")
			if resize := strings.Contains(want, "avatars/collab"); resize != (len(queued) == 1 &&
				strings.Contains(queued[0], `"args":[1790002],"class":"GenerateAvatarVariantJob"`)) {
				t.Errorf("queue:low %v", queued)
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

func TestACoffeeProductRedirectsToCoffee(t *testing.T) {
	e := newTestEnv(t)
	if _, err := testdb.Open(t).Exec("UPDATE links SET native_type = 'coffee' WHERE id = ?", productID); err != nil {
		t.Fatal(err)
	}
	for target, robots := range map[string]string{"/l/guide": "", "/l/guide/SAVE10": "noindex"} {
		w := e.get(host, target, nil)
		if w.Code != http.StatusFound || w.Header().Get("Location") != "https://"+host+"/coffee" || e.railsHit != nil ||
			w.Header().Get("X-Robots-Tag") != robots {
			t.Errorf("%s: %d %q %q %q, Rails hit: %v", target, w.Code, w.Header().Get("Location"), w.Header().Get("X-Robots-Tag"),
				w.Header().Get("X-Go-Web-Fallback"), e.railsHit != nil)
		}
	}
}

// recoverable_hidden_variant_rich_content? reads the Variants' pages for the product-level check,
// but a SKU's summary is its own pages': here they embed one of its two files.
func TestASKUSummarizesItsOwnPages(t *testing.T) {
	const size, small, sku = int64(1_799_941), int64(1_799_942), int64(1_799_943)
	const embedded, other = int64(1_799_944), int64(1_799_945)
	e := newTestEnv(t)
	conn := testdb.Open(t)
	mustExec(t, conn, "UPDATE links SET flags = flags | ? WHERE id = ?", productSkusEnabled|productSameRichContentForAllVariants, productID)
	testdb.Insert(t, conn, "variant_categories", map[string]any{"id": size, "link_id": productID, "title": "Size"})
	testdb.Insert(t, conn, "base_variants", map[string]any{"id": small, "type": "Variant", "variant_category_id": size, "name": "Small",
		"price_difference_cents": 0, "created_at": testNow, "updated_at": testNow})
	testdb.Insert(t, conn, "rich_contents", map[string]any{"id": int64(1_799_946), "entity_type": "BaseVariant", "entity_id": small,
		"title": "Chapter one", "description": `[]`, "position": 0, "created_at": testNow, "updated_at": testNow})
	testdb.Insert(t, conn, "base_variants", map[string]any{"id": sku, "type": "Sku", "link_id": productID, "name": "A",
		"price_difference_cents": 0, "created_at": testNow, "updated_at": testNow})
	for i, id := range []int64{embedded, other} {
		testdb.Insert(t, conn, "product_files", map[string]any{"id": id, "link_id": productID, "filetype": "pdf", "size": 2048,
			"url": "https://s3.amazonaws.com/gumroad/attachments/x/y/original/a.pdf", "created_at": testNow, "updated_at": testNow})
		testdb.Insert(t, conn, "base_variants_product_files", map[string]any{"id": int64(1_799_950 + i), "base_variant_id": sku,
			"product_file_id": id})
	}
	testdb.Insert(t, conn, "rich_contents", map[string]any{"id": int64(1_799_947), "entity_type": "BaseVariant", "entity_id": sku,
		"title": "Page", "description": fmt.Sprintf(`[{"type":"fileEmbed","attrs":{"id":%q,"uid":"u0"}}]`, e.ids.Encrypt(embedded)),
		"position": 0, "created_at": testNow, "updated_at": testNow})
	w := e.get(host, "/l/guide", nil)
	if w.Code != http.StatusOK || e.railsHit != nil {
		t.Fatalf("%d %q, Rails hit: %v", w.Code, w.Header().Get("X-Go-Web-Fallback"), e.railsHit != nil)
	}
	page := html.UnescapeString(dataPage.FindStringSubmatch(w.Body.String())[1])
	want := `"file_summaries":{"product":null,"options":{"` + e.ids.Encrypt(sku) + `":{"formats":["PDF"],"total_size":2048,"count":1}}}`
	if !strings.Contains(page, want) {
		t.Errorf("want %s", want)
	}
}

// authenticityToken is the per-request masked CSRF token, in the shared props and the csrf-token meta tag.
var authenticityToken = regexp.MustCompile(`"authenticity_token":"[^"]*"|"name":"csrf-token","content":"[^"]*"`)

// An Inertia visit gets the page object the document carries, as JSON, and none of the layout's
// headers; a custom HTML page's before_action answers it with the same wrapper as any visit.
func TestAnInertiaVisitGetsThePageObject(t *testing.T) {
	e := newTestEnv(t)
	conn := testdb.Open(t)
	visitHeaders := map[string]string{"X-Inertia": "true", "X-Requested-With": "XMLHttpRequest"}
	doc := e.get(host, "/l/guide", nil)
	visit := e.get(host, "/l/guide", visitHeaders)
	if visit.Code != http.StatusOK || e.railsHit != nil {
		t.Fatalf("%d %q", visit.Code, visit.Header().Get("X-Go-Web-Fallback"))
	}
	h := visit.Header()
	if h.Get("Content-Type") != "application/json; charset=utf-8" || h.Get("X-Inertia") != "true" || h.Get("Vary") != "X-Inertia, Origin" ||
		h.Get("Link") != "" || h.Get("Content-Security-Policy") != doc.Header().Get("Content-Security-Policy") {
		t.Errorf("headers %v", h)
	}
	page := html.UnescapeString(dataPage.FindStringSubmatch(doc.Body.String())[1])
	if got, want := authenticityToken.ReplaceAllString(visit.Body.String(), ""), authenticityToken.ReplaceAllString(page, ""); got != want {
		t.Errorf("page object\n%s\nwant\n%s", got, want)
	}
	customHTML(t, e, conn)
	wrapper := e.get(host, "/l/guide", nil)
	w := e.get(host, "/l/guide", visitHeaders)
	if w.Code != http.StatusOK || e.railsHit != nil || w.Header().Get("X-Inertia") != "" ||
		csrfMeta.ReplaceAllString(w.Body.String(), "") != csrfMeta.ReplaceAllString(wrapper.Body.String(), "") {
		t.Errorf("custom html: %d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
}

// Only ?wanted=true's cart_item reads these, so any other view ignores them; display and as_embed
// reach the shared props and the layout, and native=true skips a custom HTML page.
// buyer_currency_preference reads ?currency= before the cookie, and only a currency it offers.
func TestParamsTheShowPageReads(t *testing.T) {
	e := newTestEnv(t)
	conn := testdb.Open(t)
	// Before any request: the flag client caches the first read of buyer_local_currency.
	e.localEUR("0.92345")
	e.redis.Set("currencies:GBP", "0.8")
	const cartOnly = "/l/guide?option=x&variant=y&price=5&recurrence=monthly&rent=true&monthly=true"
	plain := e.get(host, "/l/guide", nil)
	w := e.get(host, cartOnly, nil)
	if w.Code != http.StatusOK || e.railsHit != nil {
		t.Fatalf("cart params: %d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
	page := func(body string) string {
		return strings.Replace(authenticityToken.ReplaceAllString(html.UnescapeString(dataPage.FindStringSubmatch(body)[1]), ""),
			strings.ReplaceAll(cartOnly, "&", `\u0026`), "/l/guide", 1)
	}
	if page(w.Body.String()) != page(plain.Body.String()) {
		t.Error("the cart's params changed the page")
	}
	if body := e.get(host, "/l/guide?display=mobile_app", nil).Body.String(); !strings.Contains(html.UnescapeString(body), `"is_mobile_app_web_view":true`) {
		t.Error("display=mobile_app")
	}
	if body := e.get(host, "/l/guide?as_embed=1", nil).Body.String(); !strings.Contains(body, `style="background: transparent"`) {
		t.Error("as_embed=1")
	}
	// A bare key is nil, which the layout reads as false.
	if body := e.get(host, "/l/guide?as_embed", nil).Body.String(); strings.Contains(body, "background: transparent") {
		t.Error("a bare as_embed")
	}
	gbpCookie := map[string]string{"Cookie": "gumroad_buyer_currency=GBP"}
	for target, want := range map[string]string{"/l/guide?currency=EUR": "eur", "/l/guide?currency=+": "gbp", "/l/guide?currency=xyz": "usd"} {
		w := e.get(host, target, gbpCookie)
		if w.Code != http.StatusOK || !strings.Contains(html.UnescapeString(w.Body.String()), `"buyer_currency_shown":"`+want+`"`) {
			t.Errorf("%s: %d %q, want %s", target, w.Code, w.Header().Get("X-Go-Web-Fallback"), want)
		}
	}
	headers := e.dryRun(host, "/l/guide?currency[]=eur", testNow)
	if w := e.get(host, "/l/guide?currency[]=eur", headers); w.Header().Get("X-Go-Web-Fallback") != "param currency" {
		t.Errorf("an Array currency: %d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
	customHTML(t, e, conn)
	if body := e.get(host, "/l/guide?native=true", nil).Body.String(); strings.Contains(body, "gumroad-landing-frame") || !strings.Contains(body, productComponent) {
		t.Error("native=true")
	}
}

// Journey's normalize_path routes /l/:id/ as /l/:id, and the page keeps the URL it was asked for.
func TestATrailingSlash(t *testing.T) {
	e := newTestEnv(t)
	testdb.Open(t)
	w := e.get(host, "/l/guide/?a=1", nil)
	if w.Code != http.StatusOK || e.railsHit != nil {
		t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
	if page := html.UnescapeString(dataPage.FindStringSubmatch(w.Body.String())[1]); !strings.Contains(page, `"url":"/l/guide/?a=1"`) {
		t.Errorf("page url in %s", page[strings.LastIndex(page, `"url"`):])
	}
}
