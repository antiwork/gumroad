package downloads

import (
	"context"
	"html"
	"net/http"
	"net/http/httptest"
	"net/url"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/delivery"
	"github.com/antiwork/gumroad/go_web/internal/inertia"
	"github.com/antiwork/gumroad/go_web/internal/pages"
	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/session/sessiontest"
	"github.com/antiwork/gumroad/go_web/internal/session/testdb"
	"github.com/antiwork/gumroad/go_web/internal/storage"
	"github.com/antiwork/gumroad/go_web/internal/vite"
	"github.com/antiwork/gumroad/go_web/internal/web"
)

const richContentID = int64(1_780_601)

type presentFiles struct{}

func (presentFiles) Exists(context.Context, string) (bool, error) { return true, nil }

// newPageEnv is newTestEnv with the full page turned on and a rich content page for the
// product.
func newPageEnv(t *testing.T) *testEnv {
	t.Helper()
	e := newConfiguredTestEnv(t, nil, func(e *testEnv, c *Config) {
		manifest, err := vite.LoadDir(c.Env.AssetHost(), "../vite/testdata")
		if err != nil {
			t.Fatal(err)
		}
		layout, err := inertia.NewLayout(inertia.LayoutConfig{OGNamespace: "gumroad", DNSPrefetch: []string{c.Env.AssetHost()},
			ActionCableURL: "wss://cable.gumroad.com/cable", Manifest: manifest})
		if err != nil {
			t.Fatal(err)
		}
		csp, err := web.NewCSP(c.Env, func(_, f string) string { return f })
		if err != nil {
			t.Fatal(err)
		}
		c.Pages = &PageConfig{
			Layout:         layout,
			CSP:            csp,
			Shared:         pages.NewShared(c.Env, func(context.Context) (bool, error) { return true, nil }),
			Avatars:        &storage.Avatars{DB: c.DB, Exists: presentFiles{}, AssetHost: c.Env.AssetHost(), Now: func() time.Time { return testNow }},
			Content:        delivery.ContentConfig{IDs: c.IDs, S3BaseURL: "https://s3.amazonaws.com/gumroad/", AssetHost: c.Env.AssetHost()},
			EmailDigestKey: "digest-key", DropboxAPIKey: "dropbox", IOSAppID: "916819108", AndroidBundleID: "com.gumroad.app",
			NewNonce: func() string { return "NONCE" },
		}
		c.DryRunKey = pages.DryRunKey(testSecretKeyBase)
	})
	testdb.Insert(t, e.db, "rich_contents", map[string]any{"id": richContentID, "entity_id": productID, "entity_type": "Link",
		"title": "Welcome", "position": 0, "description": `[{"type": "paragraph", "content": [{"text": "Hello <there>", "type": "text"}]}]`,
		"created_at": testNow, "updated_at": testNow})
	testdb.CleanupWhere(t, e.db, "consumption_events", "url_redirect_id BETWEEN ? AND ?", purchaseID, purchaseID+99)
	return e
}

// page requests the full page with a confirmation cookie, as a buyer back from the email.
func (e *testEnv) page(token string, headers map[string]string) *httptest.ResponseRecorder {
	e.t.Helper()
	e.railsHit = nil
	r := httptest.NewRequest("GET", "/d/"+token, nil)
	r.Host = "gumroad.com"
	r.RemoteAddr = "10.1.0.9:5000"
	r.Header.Set("X-Forwarded-Proto", "https")
	r.Header.Set("X-Forwarded-For", buyerIP)
	r.Header.Set("Accept", "text/html")
	r.Header.Set("User-Agent", "Mozilla/5.0 (Macintosh)")
	r.Header.Set("Cookie", confirmedCookie+"="+url.QueryEscape(sessiontest.Encrypt(e.t, testSecretKeyBase, confirmedCookie, []byte(`"`+token+`"`), time.Time{})))
	for k, v := range headers {
		r.Header.Set(k, v)
	}
	w := httptest.NewRecorder()
	e.handler.ServeHTTP(w, r)
	return w
}

func pageProps(t *testing.T, body string) *rails.Hash {
	t.Helper()
	m := regexp.MustCompile(`data-page="([^"]*)"`).FindStringSubmatch(body)
	if m == nil {
		t.Fatalf("no data-page in %.300s", body)
	}
	v, err := rails.ParseJSON([]byte(html.UnescapeString(m[1])))
	if err != nil {
		t.Fatal(err)
	}
	return v.(*rails.Hash).Value("props").(*rails.Hash)
}

func TestTheFullPageRendersAndRecordsTheView(t *testing.T) {
	e := newPageEnv(t)
	token := e.purchase(productID, map[string]any{"email": "buyer@example.com", "price_cents": 500, "created_at": testNow}, map[string]any{"flags": 0})
	w := e.page(token, nil)
	if w.Code != http.StatusOK || e.railsHit != nil {
		t.Fatalf("status %d, rails %v: %s", w.Code, e.railsHit != nil, w.Header().Get("X-Go-Web-Fallback"))
	}
	if got := strings.Join(cookieNames(w), " "); got != "_gumroad_guid confirmed_redirect XSRF-TOKEN _gumroad_app_session" {
		t.Errorf("cookies %s", got)
	}
	for k, want := range map[string]string{"X-Robots-Tag": "noindex", "Vary": "X-Inertia, Origin", "Content-Type": "text/html; charset=utf-8"} {
		if got := w.Header().Get(k); got != want {
			t.Errorf("%s: %q", k, got)
		}
	}
	if !strings.Contains(w.Header().Get("Content-Security-Policy"), "'nonce-NONCE' 'unsafe-inline'") {
		t.Errorf("CSP %s", w.Header().Get("Content-Security-Policy"))
	}
	body := w.Body.String()
	for _, want := range []string{
		`<title inertia="title">Download</title>`,
		`<link rel="shortcut icon" href="https://assets.gumroad.com/images/gumroad-default-avatar-5.png" inertia="shortcut-icon">`,
		`<meta name="apple-itunes-app" content="app-id=916819108, app-argument=https://gumroad.com/d/` + token + `"`,
		`class="group/body mac"`,
	} {
		if !strings.Contains(body, want) {
			t.Errorf("missing %s", want)
		}
	}

	props := pageProps(t, body)
	var keys []string
	for _, k := range props.Keys() {
		keys = append(keys, k)
	}
	wantKeys := "errors design_settings domain_settings user_agent_info logged_in_user current_seller csp_nonce locale feature_flags " +
		"authenticity_token flash title content product_has_third_party_analytics seller_analytics terms_page_url token redirect_id " +
		"purchase is_mobile_app_web_view content_unavailability_reason_code add_to_library_option dropbox_api_key _inertia_meta"
	if got := strings.Join(keys, " "); got != wantKeys {
		t.Errorf("props:\n got %s\nwant %s", got, wantKeys)
	}
	content := props.Value("content").(*rails.Hash)
	items := content.Value("content_items").([]any)
	if len(items) != 2 || items[0].(*rails.Hash).Value("file_name") != nil || items[0].(*rails.Hash).Value("extension") != "PDF" {
		t.Errorf("content items %s", rails.EncodeJSON(items))
	}
	pages := content.Value("rich_content_pages").([]any)
	if len(pages) != 1 || rails.EncodeJSON(pages[0].(*rails.Hash).Value("description")) !=
		`{"type":"doc","content":[{"type":"paragraph","content":[{"text":"Hello \u003cthere\u003e","type":"text"}]}]}` {
		t.Errorf("rich content %s", rails.EncodeJSON(pages))
	}
	purchase := props.Value("purchase").(*rails.Hash)
	if purchase.Value("email") != "buyer@example.com" || purchase.Value("has_invoice") != true || purchase.Value("allows_review") != true ||
		purchase.Value("product_long_url") != "https://gowebdownloadseller.gumroad.com/l/gowebdl101" {
		t.Errorf("purchase %s", rails.EncodeJSON(purchase))
	}
	if props.Value("add_to_library_option") != "none" || props.Value("csp_nonce") != "NONCE" {
		t.Errorf("props %v %v", props.Value("add_to_library_option"), props.Value("csp_nonce"))
	}

	// The after_actions' writes.
	var events, uses, flags int64
	e.db.QueryRow("SELECT COUNT(*) FROM consumption_events WHERE url_redirect_id = ? AND event_type = 'view' AND platform = 'web' AND link_id = ?"+
		" AND json_data = ?", nextPurchase, productID, `{"folder_id":null,"ip_address":"`+buyerIP+`"}`).Scan(&events)
	e.db.QueryRow("SELECT COALESCE(uses, 0), flags FROM url_redirects WHERE id = ?", nextPurchase).Scan(&uses, &flags)
	if events != 1 || uses != 1 || flags&urlRedirectHasBeenSeen == 0 {
		t.Errorf("events %d uses %d flags %d", events, uses, flags)
	}
}

func TestTheFullPageLeavesToRailsWhatItDoesNotPort(t *testing.T) {
	e := newPageEnv(t)
	for name, token := range map[string]string{
		"licensed product": e.purchase(productID, nil, nil),
		"gift sender":      e.purchase(productID, map[string]any{"flags": purchaseIsGiftSender}, nil),
	} {
		if name == "licensed product" {
			e.db.Exec("UPDATE links SET flags = flags | ? WHERE id = ?", productIsLicensed, productID)
		}
		w := e.page(token, nil)
		if e.railsHit == nil || w.Body.String() != "rails" {
			t.Errorf("%s: not handed to Rails: %d", name, w.Code)
		}
		e.db.Exec("UPDATE links SET flags = flags & ~? WHERE id = ?", productIsLicensed, productID)
	}
	// An Inertia visit to the page goes to Rails too.
	token := e.purchase(productID, nil, nil)
	if e.page(token, map[string]string{"X-Inertia": "true"}); e.railsHit == nil {
		t.Error("an Inertia visit was rendered")
	}
}

func TestADryRunWritesNothingAndNamesItsFallback(t *testing.T) {
	e := newPageEnv(t)
	token := e.purchase(productID, map[string]any{"email": "buyer@example.com", "price_cents": 500}, map[string]any{"flags": 0})
	sign := func(path string, at time.Time) map[string]string {
		return map[string]string{"X-Go-Web-Dry-Run": pages.SignDryRun(pages.DryRunKey(testSecretKeyBase), "GET", "gumroad.com", path, at)}
	}
	if w := e.page(token, sign("/d/"+token, testNow)); w.Code != http.StatusOK {
		t.Fatalf("dry run: %d %s", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
	var events, uses int64
	e.db.QueryRow("SELECT COUNT(*) FROM consumption_events WHERE url_redirect_id = ?", nextPurchase).Scan(&events)
	e.db.QueryRow("SELECT COALESCE(uses, 0) FROM url_redirects WHERE id = ?", nextPurchase).Scan(&uses)
	if events != 0 || uses != 0 {
		t.Errorf("a dry run wrote: events %d uses %d", events, uses)
	}
	e.db.Exec("UPDATE links SET flags = flags | ? WHERE id = ?", productIsLicensed, productID)
	defer e.db.Exec("UPDATE links SET flags = flags & ~? WHERE id = ?", productIsLicensed, productID)
	header := sign("/d/"+token, testNow.Add(-time.Second))
	w := e.page(token, header)
	if w.Code != http.StatusNoContent || w.Header().Get("X-Go-Web-Fallback") != "licensed product" || e.railsHit != nil {
		t.Errorf("fallback in a dry run: %d %q rails %v", w.Code, w.Header().Get("X-Go-Web-Fallback"), e.railsHit != nil)
	}
	// A header works once; used again, it is refused without running the page.
	if w := e.page(token, header); w.Code != http.StatusNoContent || w.Header().Get("X-Go-Web-Fallback") != "dry run refused" || e.railsHit != nil {
		t.Errorf("a used header: %d %q rails %v", w.Code, w.Header().Get("X-Go-Web-Fallback"), e.railsHit != nil)
	}
	// Nor is one signed for another host, or one too old.
	other := map[string]string{"X-Go-Web-Dry-Run": pages.SignDryRun(pages.DryRunKey(testSecretKeyBase), "GET", "other.gumroad.com", "/d/"+token, testNow)}
	if e.page(token, other); e.railsHit == nil {
		t.Error("a header signed for another host was honored")
	}
	old := map[string]string{"X-Go-Web-Dry-Run": pages.SignDryRun(pages.DryRunKey(testSecretKeyBase), "GET", "gumroad.com", "/d/"+token, testNow.Add(-2*time.Minute))}
	if e.page(token, old); e.railsHit == nil {
		t.Error("a stale header was honored")
	}
	// A header signed for another path, or with another key, is no dry run.
	if e.page(token, sign("/d/other", testNow.Add(-2*time.Second))); e.railsHit == nil {
		t.Error("a header signed for another path was honored")
	}
}

func TestARefundedPurchasesPageIsNotFound(t *testing.T) {
	e := newPageEnv(t)
	token := e.purchase(productID, map[string]any{"stripe_refunded": true, "price_cents": 500}, nil)
	w := e.page(token, nil)
	// withdrawn_content_response raises e404 for the page, where a poll is moved to the expired page.
	if w.Code != http.StatusNotFound || len(w.Header().Values("Set-Cookie")) != 0 || e.railsHit != nil {
		t.Errorf("status %d, cookies %v, rails %v", w.Code, w.Header().Values("Set-Cookie"), e.railsHit != nil)
	}
}

func TestPartialReloadHeadersWithoutXInertiaGoToRails(t *testing.T) {
	e := newPageEnv(t)
	token := e.purchase(productID, map[string]any{"price_cents": 500}, nil)
	e.page(token, map[string]string{"X-Inertia-Partial-Component": component, "X-Inertia-Partial-Data": "audio_durations"})
	if e.railsHit == nil {
		t.Error("rendered a page inertia_rails would answer as a partial reload")
	}
}
