package beacons

import (
	"crypto/hmac"
	"crypto/md5"
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha1"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"io"
	"log/slog"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
	_ "github.com/go-sql-driver/mysql"
	"github.com/redis/go-redis/v9"

	"github.com/antiwork/gumroad/go_web/internal/geoip"
	"github.com/antiwork/gumroad/go_web/internal/geoip/geoiptest"
	"github.com/antiwork/gumroad/go_web/internal/obfuscate"
	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/session/sessiontest"
	"github.com/antiwork/gumroad/go_web/internal/session/testdb"
	"github.com/antiwork/gumroad/go_web/internal/sidekiq"
	"github.com/antiwork/gumroad/go_web/internal/web"
)

const (
	testSecretKeyBase = "go-web-test-secret-key-base"
	testMobileToken   = "test-mobile-token"
	sessionName       = "_gumroad_app_session"
)

type testEnv struct {
	app     *web.App
	db      *sql.DB
	redis   *miniredis.Miniredis
	sidekiq *miniredis.Miniredis
	ids     *obfuscate.IDs
	now     time.Time
}

// newTestEnv wires the package as main.go would. Without MySQL, db is a handle that fails
// on first use, which the cases that never query rely on.
func newTestEnv(t *testing.T, withDB bool) *testEnv {
	t.Helper()
	var conn *sql.DB
	if withDB {
		conn = testdb.Open(t)
	} else {
		var err error
		if conn, err = sql.Open("mysql", "nobody@tcp(127.0.0.1:1)/none?timeout=100ms"); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { conn.Close() })
	}
	env, err := web.LoadEnvironment(func(name string) string {
		return map[string]string{"RAILS_ENV": "production", "REVISION": "r"}[name]
	})
	if err != nil {
		t.Fatal(err)
	}
	appRedis, jobRedis := miniredis.RunT(t), miniredis.RunT(t)
	appClient := redis.NewClient(&redis.Options{Addr: appRedis.Addr()})
	jobClient := redis.NewClient(&redis.Options{Addr: jobRedis.Addr()})
	t.Cleanup(func() { appClient.Close(); jobClient.Close() })
	ids, _ := obfuscate.New("test", "1234")
	reader, err := geoip.Open(geoiptest.WriteDatabase(t))
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 11, 2, 10, 0, 0, 123456789, time.UTC)
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	app := web.NewApp(env, logger, appClient)
	err = Register(app, Deps{
		Env: env, Stack: rails.NewStack(env, ""), DB: conn, Redis: appClient, Sidekiq: &sidekiq.Client{Redis: jobClient, Now: func() time.Time { return now }},
		GeoIP: reader, IDs: ids, SecretKeyBase: testSecretKeyBase, MobileToken: testMobileToken,
		Now: func() time.Time { return now },
	})
	if err != nil {
		t.Fatal(err)
	}
	return &testEnv{app: app, db: conn, redis: appRedis, sidekiq: jobRedis, ids: ids, now: now}
}

type call struct {
	method, path, host string
	json               any
	form               string
	headers            map[string]string
	session            map[string]any
	cookies            map[string]string
	csrf               bool
}

func (e *testEnv) do(t *testing.T, c call) *httptest.ResponseRecorder {
	t.Helper()
	var body io.Reader
	contentType := ""
	switch {
	case c.json != nil:
		data, _ := json.Marshal(c.json)
		body, contentType = strings.NewReader(string(data)), "application/json"
	case c.form != "":
		body, contentType = strings.NewReader(c.form), "application/x-www-form-urlencoded"
	}
	r := httptest.NewRequest(c.method, c.path, body)
	r.Host = c.host
	if r.Host == "" {
		r.Host = "gumroad.com"
	}
	r.RemoteAddr = "10.0.0.5:1234"
	r.Header.Set("X-Forwarded-Proto", "https")
	r.Header.Set("Accept", "application/json, text/html")
	if contentType != "" {
		r.Header.Set("Content-Type", contentType)
	}
	cookies := map[string]string{}
	for k, v := range c.cookies {
		cookies[k] = v
	}
	if c.session != nil || c.csrf {
		s := map[string]any{"session_id": "abc"}
		for k, v := range c.session {
			s[k] = v
		}
		real := make([]byte, 32)
		rand.Read(real)
		s["_csrf_token"] = base64.RawURLEncoding.EncodeToString(real)
		raw, _ := json.Marshal(s)
		cookies[sessionName] = sessiontest.Encrypt(t, testSecretKeyBase, sessionName, raw, e.now.Add(time.Hour))
		if c.csrf {
			r.Header.Set("X-CSRF-Token", sessiontest.MaskedGlobalToken(s["_csrf_token"].(string)))
		}
	}
	var parts []string
	for k, v := range cookies {
		parts = append(parts, k+"="+url.QueryEscape(v))
	}
	if len(parts) > 0 {
		r.Header.Set("Cookie", strings.Join(parts, "; "))
	}
	for k, v := range c.headers {
		if v == "" {
			r.Header.Del(k)
		} else {
			r.Header.Set(k, v)
		}
	}
	w := httptest.NewRecorder()
	e.app.ServeHTTP(w, r)
	return w
}

func signedInAs(id int64) map[string]any {
	return map[string]any{
		"warden.user.user.key":     []any{[]any{id}, "$2a$11$abcdefghijklmnopqrstuv"},
		"warden.user.user.session": map[string]any{"last_sign_in_at": 1_790_000_000},
	}
}

func jobs(t *testing.T, e *testEnv) []map[string]any {
	t.Helper()
	list, _ := e.sidekiq.List("queue:default")
	var out []map[string]any
	for i := len(list) - 1; i >= 0; i-- {
		var job map[string]any
		if err := json.Unmarshal([]byte(list[i]), &job); err != nil {
			t.Fatal(err)
		}
		out = append(out, job)
	}
	return out
}

func expect(t *testing.T, w *httptest.ResponseRecorder, status int, body string) {
	t.Helper()
	if w.Code != status || w.Body.String() != body {
		t.Fatalf("got %d %q, want %d %q", w.Code, w.Body.String(), status, body)
	}
}

func setCookies(w *httptest.ResponseRecorder) []string { return w.Header().Values("Set-Cookie") }

// --- cases that never reach MySQL ---

func TestMediaLocationsRendersRailsJSONAndMintsTheGuid(t *testing.T) {
	e := newTestEnv(t, false)
	w := e.do(t, call{method: "POST", path: "/media_locations.json", csrf: true, json: map[string]any{"platform": "web"}})
	expect(t, w, 200, `{"success":false}`)
	h := w.Header()
	if h.Get("Content-Type") != "application/json; charset=utf-8" || h.Get("Cache-Control") != "max-age=0, private, must-revalidate" ||
		h.Get("ETag") != web.ETag(`{"success":false}`) || h.Get("Vary") != "Origin" {
		t.Errorf("headers = %v", h)
	}
	if cookies := setCookies(w); len(cookies) != 1 || !strings.HasPrefix(cookies[0], "_gumroad_guid=") ||
		!strings.HasSuffix(cookies[0], "; domain=gumroad.com; path=/; expires=Sun, 02 Nov 2036 10:00:00 GMT; httponly; samesite=lax; secure") {
		t.Errorf("Set-Cookie = %v", cookies)
	}

	// Without a valid token the null session swallows the cookie jar, but the action runs.
	w = e.do(t, call{method: "POST", path: "/media_locations", json: map[string]any{}})
	expect(t, w, 200, `{"success":false}`)
	if len(setCookies(w)) != 0 || w.Header().Get("Vary") != "Accept, Origin" {
		t.Errorf("Set-Cookie %v, Vary %q", setCookies(w), w.Header().Get("Vary"))
	}

	w = e.do(t, call{method: "POST", path: "/media_locations", json: map[string]any{}, cookies: map[string]string{"_gumroad_guid": "existing"}, csrf: true})
	if len(setCookies(w)) != 0 {
		t.Errorf("an existing guid is kept, got %v", setCookies(w))
	}
}

func TestPostsWithANullOriginAreUnprocessable(t *testing.T) {
	e := newTestEnv(t, false)
	w := e.do(t, call{method: "POST", path: "/media_locations", csrf: true, json: map[string]any{}, headers: map[string]string{"Origin": "null"}})
	expect(t, w, 422, `{"status":422,"error":"Unprocessable Content"}`)
	if w.Header().Get("Content-Type") != "application/json; charset=utf-8" {
		t.Errorf("Content-Type = %q", w.Header().Get("Content-Type"))
	}
	w = e.do(t, call{method: "POST", path: "/media_locations", csrf: true, json: map[string]any{}, headers: map[string]string{"Origin": "null", "Accept": "text/html"}})
	if w.Code != 422 || !strings.Contains(w.Body.String(), "<html") {
		t.Errorf("html 422 = %d %q", w.Code, w.Body.String()[:40])
	}
	// A foreign origin is only unverified, which nulls the session.
	w = e.do(t, call{method: "POST", path: "/media_locations", csrf: true, json: map[string]any{}, headers: map[string]string{"Origin": "https://evil.example"}})
	expect(t, w, 200, `{"success":false}`)
	if len(setCookies(w)) != 0 {
		t.Error("an unverified request writes no cookies")
	}
}

func TestMalformedRequestsFailLikeRails(t *testing.T) {
	e := newTestEnv(t, false)
	r := httptest.NewRequest("POST", "/media_locations", strings.NewReader(`{"platform":`))
	r.Host = "gumroad.com"
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("Accept", "application/json")
	w := httptest.NewRecorder()
	e.app.ServeHTTP(w, r)
	expect(t, w, 400, `{"status":400,"error":"Bad Request"}`)

	w = e.do(t, call{method: "POST", path: "/media_locations?a=%zz", json: map[string]any{}})
	expect(t, w, 400, `{"success":false}`)
	w = e.do(t, call{method: "POST", path: "/media_locations?a=%zz", json: map[string]any{}, headers: map[string]string{"Accept": "text/html"}})
	expect(t, w, 400, ``)

	w = e.do(t, call{method: "POST", path: "/media_locations", json: map[string]any{}, headers: map[string]string{"Accept": "nonsense"}})
	expect(t, w, 406, ``)
}

func TestMobileMediaLocationsChecksTheMobileTokenThenDoorkeeper(t *testing.T) {
	e := newTestEnv(t, false)
	w := e.do(t, call{method: "POST", path: "/mobile/media_locations", host: "api.gumroad.com", json: map[string]any{"mobile_token": "wrong"}})
	expect(t, w, 401, `{"success":false,"message":"Invalid request"}`)

	w = e.do(t, call{method: "POST", path: "/mobile/media_locations.json", host: "api.gumroad.com", json: map[string]any{"mobile_token": testMobileToken},
		headers: map[string]string{"Origin": "https://example.com"}})
	expect(t, w, 401, ``)
	h := w.Header()
	if h.Get("WWW-Authenticate") != `Bearer realm="Doorkeeper", error="invalid_token", error_description="The access token is invalid"` ||
		h.Get("Cache-Control") != "no-store" || h.Get("Content-Type") != "application/json" {
		t.Errorf("headers = %v", h)
	}
	if h.Get("Access-Control-Allow-Origin") != "*" || h.Get("Access-Control-Max-Age") != "7200" {
		t.Errorf("rack-cors headers = %v", h)
	}

	w = e.do(t, call{method: "POST", path: "/mobile/media_locations", json: map[string]any{"mobile_token": testMobileToken}})
	expect(t, w, 404, `{"status":404,"error":"Not Found"}`)
}

func TestRoutesOutsideTheirHostsAreNotFound(t *testing.T) {
	e := newTestEnv(t, false)
	w := e.do(t, call{method: "GET", path: "/links/abc/increment_views", host: "gumroad-analytics.com"})
	expect(t, w, 404, `{"status":404,"error":"Not Found"}`)
	w = e.do(t, call{method: "GET", path: "/links/a.b/increment_views", headers: map[string]string{"Accept": "text/html"}})
	if w.Code != 404 || !strings.Contains(w.Body.String(), "Page not found (404)") {
		t.Errorf("got %d", w.Code)
	}
}

func TestCartItemsCountRefusesWhatRailsRendersWithInertia(t *testing.T) {
	e := newTestEnv(t, false)
	w := e.do(t, call{method: "GET", path: "/cart_items_count", headers: map[string]string{"Accept": "text/html"}})
	expect(t, w, 406, ``)
}

// --- cases backed by MySQL ---

const (
	sellerID   = int64(1_500_101)
	buyerID    = int64(1_500_102)
	adminID    = int64(1_500_103)
	suspendID  = int64(1_500_104)
	productID  = int64(1_500_101)
	purchaseID = int64(1_500_101)
	redirectID = int64(1_500_101)
	videoID    = int64(1_500_101)
	epubID     = int64(1_500_102)
	zipID      = int64(1_500_103)
	permalink  = "gowebbeacon"
)

func seed(t *testing.T, e *testEnv) {
	t.Helper()
	db, now := e.db, e.now
	testdb.User(t, db, sellerID, map[string]any{"username": "gowebbeaconseller"})
	testdb.User(t, db, buyerID, nil)
	testdb.User(t, db, adminID, map[string]any{"flags": 1 | 1<<27})
	testdb.User(t, db, suspendID, map[string]any{"user_risk_state": "suspended_for_fraud"})
	testdb.Insert(t, db, "links", map[string]any{"id": productID, "user_id": sellerID, "name": "Beacon", "unique_permalink": permalink, "price_cents": 500})
	testdb.Insert(t, db, "purchases", map[string]any{"id": purchaseID, "link_id": productID})
	testdb.Insert(t, db, "url_redirects", map[string]any{"id": redirectID, "purchase_id": purchaseID, "token": "gowebbeacontoken"})
	for id, kind := range map[int64][2]string{videoID: {"mp4", "video"}, epubID: {"epub", "document"}, zipID: {"zip", "archive"}} {
		testdb.Insert(t, db, "product_files", map[string]any{"id": id, "filetype": kind[0], "filegroup": kind[1], "created_at": now, "updated_at": now})
	}
	testdb.Insert(t, db, "custom_domains", map[string]any{"id": int64(1_500_101), "domain": "gowebbeacon-shop.example.com", "user_id": sellerID})
	testdb.Insert(t, db, "custom_domains", map[string]any{"id": int64(1_500_102), "domain": "gowebbeacon-product.example.net", "product_id": productID})
	testdb.CleanupWhere(t, db, "media_locations", "purchase_id = ?", purchaseID)
	testdb.CleanupWhere(t, db, "events", "link_id = ? OR user_id IN (?, ?, ?)", productID, sellerID, buyerID, adminID)
	testdb.CleanupWhere(t, db, "events", "browser = ?", "go-web-beacons-test")
	testdb.CleanupWhere(t, db, "signup_events", "browser = ?", "go-web-beacons-test")
}

func (e *testEnv) mediaParams(file int64, extra map[string]any) map[string]any {
	params := map[string]any{
		"platform": "web", "url_redirect_id": e.ids.Encrypt(redirectID), "product_file_id": e.ids.Encrypt(file),
		"purchase_id": e.ids.Encrypt(purchaseID), "location": 42, "consumed_at": "2026-11-02T09:00:00.750Z",
	}
	for k, v := range extra {
		params[k] = v
	}
	return params
}

type mediaRow struct {
	location   int
	unit       string
	consumedAt time.Time
	cfi        sql.NullString
	updatedAt  time.Time
}

func readMediaRow(t *testing.T, e *testEnv, file int64) *mediaRow {
	t.Helper()
	row := &mediaRow{}
	err := e.db.QueryRow(`SELECT location, unit, consumed_at, epub_cfi, updated_at FROM media_locations WHERE purchase_id = ? AND product_file_id = ?`,
		purchaseID, file).Scan(&row.location, &row.unit, &row.consumedAt, &row.cfi, &row.updatedAt)
	if err == sql.ErrNoRows {
		return nil
	}
	if err != nil {
		t.Fatal(err)
	}
	return row
}

func TestMediaLocationsRecordsAndOnlyMovesForward(t *testing.T) {
	e := newTestEnv(t, true)
	seed(t, e)

	w := e.do(t, call{method: "POST", path: "/media_locations", csrf: true, json: e.mediaParams(videoID, nil)})
	expect(t, w, 200, `{"success":true}`)
	row := readMediaRow(t, e, videoID)
	if row == nil || row.location != 42 || row.unit != "seconds" || !row.consumedAt.Equal(time.Date(2026, 11, 2, 9, 0, 0, 0, time.UTC)) ||
		!row.updatedAt.Equal(e.now.Truncate(time.Microsecond)) {
		t.Fatalf("row = %+v", row)
	}

	// Within the same second the stored time is behind the sent one, so Rails still saves.
	w = e.do(t, call{method: "POST", path: "/media_locations", json: e.mediaParams(videoID, map[string]any{"location": "43.9", "consumed_at": "2026-11-02T09:00:00.900Z"})})
	expect(t, w, 200, `{"success":true}`)
	if row := readMediaRow(t, e, videoID); row.location != 43 {
		t.Fatalf("row = %+v", row)
	}
	w = e.do(t, call{method: "POST", path: "/media_locations", json: e.mediaParams(videoID, map[string]any{"location": 10, "consumed_at": "2026-11-02T08:00:00Z"})})
	expect(t, w, 200, `{"success":false}`)
	if row := readMediaRow(t, e, videoID); row.location != 43 {
		t.Fatalf("an older position overwrote a newer one: %+v", row)
	}

	// Without purchase_id the url redirect's purchase is used; PDT is the iOS app's format.
	params := e.mediaParams(videoID, map[string]any{"platform": "iphone", "consumed_at": "2026-11-02T02:00:00PDT"})
	delete(params, "purchase_id")
	w = e.do(t, call{method: "POST", path: "/media_locations", json: params})
	expect(t, w, 200, `{"success":true}`)
	var consumed time.Time
	e.db.QueryRow(`SELECT consumed_at FROM media_locations WHERE purchase_id = ? AND platform = 'iphone'`, purchaseID).Scan(&consumed)
	if !consumed.Equal(time.Date(2026, 11, 2, 9, 0, 0, 0, time.UTC)) {
		t.Errorf("consumed_at = %v", consumed)
	}
}

func TestMediaLocationsRefusesWhatRecordMediaLocationRefuses(t *testing.T) {
	e := newTestEnv(t, true)
	seed(t, e)
	for name, params := range map[string]map[string]any{
		"unknown platform":       e.mediaParams(videoID, map[string]any{"platform": "tv"}),
		"blank location":         e.mediaParams(videoID, map[string]any{"location": ""}),
		"not consumable":         e.mediaParams(zipID, nil),
		"bad cfi":                e.mediaParams(epubID, map[string]any{"epub_cfi": "epubcfi(nope)", "location": 50}),
		"cfi with bad percent":   e.mediaParams(epubID, map[string]any{"epub_cfi": "epubcfi(/6/4!/4/2)", "location": 150}),
		"undecryptable purchase": e.mediaParams(videoID, map[string]any{"purchase_id": "nope"}),
		"unparsed consumed_at":   e.mediaParams(videoID, map[string]any{"consumed_at": "1441819610"}),
	} {
		w := e.do(t, call{method: "POST", path: "/media_locations", json: params})
		if w.Code != 200 || w.Body.String() != `{"success":false}` {
			t.Errorf("%s: %d %s", name, w.Code, w.Body.String())
		}
	}
	if readMediaRow(t, e, videoID) != nil || readMediaRow(t, e, epubID) != nil {
		t.Fatal("nothing must be stored")
	}

	w := e.do(t, call{method: "POST", path: "/media_locations", json: e.mediaParams(int64(1_999_990), nil)})
	expect(t, w, 404, `{"status":404,"error":"Not Found"}`)
	w = e.do(t, call{method: "POST", path: "/media_locations", json: e.mediaParams(videoID, map[string]any{"consumed_at": "2026-13-01T00:00:00Z"})})
	expect(t, w, 500, `{"status":500,"error":"Internal Server Error"}`)

	w = e.do(t, call{method: "POST", path: "/media_locations", json: e.mediaParams(epubID, map[string]any{"epub_cfi": "epubcfi(/6/4!/4/2)", "location": "55.5"})})
	expect(t, w, 200, `{"success":true}`)
	if row := readMediaRow(t, e, epubID); row == nil || row.unit != "percentage" || row.cfi.String != "epubcfi(/6/4!/4/2)" || row.location != 55 {
		t.Fatalf("epub row = %+v", row)
	}
}

func TestMediaLocationsRoutesOnlyOnStorefrontHosts(t *testing.T) {
	e := newTestEnv(t, true)
	seed(t, e)
	for host, want := range map[string]int{
		"gowebbeacon-shop.example.com":    200,
		"gowebbeaconseller.gumroad.com":   200,
		"gowebbeacon-product.example.net": 404,
		"nobody-here.example.org":         404,
	} {
		w := e.do(t, call{method: "POST", path: "/media_locations", host: host, json: map[string]any{}})
		if w.Code != want {
			t.Errorf("%s: %d %s", host, w.Code, w.Body.String())
		}
	}
}

func TestIncrementViewsQueuesAProductPageView(t *testing.T) {
	e := newTestEnv(t, true)
	seed(t, e)
	w := e.do(t, call{method: "POST", path: "/links/" + permalink + "/increment_views", csrf: true,
		cookies: map[string]string{"_gumroad_guid": "guid-1"},
		headers: map[string]string{"User-Agent": "Mozilla/5.0", "CF-Connecting-IP": "81.2.69.160"},
		json:    map[string]any{"referrer": []any{"", "https://www.Example.com/café"}, "view_url": "/l/" + permalink, "plugins": "PDF Viewer"}})
	expect(t, w, 200, `{"success":true}`)

	list := jobs(t, e)
	if len(list) != 1 {
		t.Fatalf("jobs = %v", list)
	}
	job := list[0]
	if job["class"] != "ElasticsearchIndexerWorker" || job["queue"] != "default" || job["retry"] != float64(10) || job["backtrace"] != true {
		t.Fatalf("job = %v", job)
	}
	args := job["args"].([]any)
	params := args[1].(map[string]any)
	body := params["body"].(map[string]any)
	want := map[string]any{
		"product_id": float64(productID), "country": "United Kingdom", "state": "WBK", "referrer_domain": "example.com",
		"timestamp": "2026-11-02T10:00:00Z", "seller_id": float64(sellerID), "user_id": nil, "ip_address": "81.2.69.160",
		"url": "/l/" + permalink, "browser_guid": "guid-1", "browser_fingerprint": eventFingerprintFor("Mozilla/5.0", "PDF Viewer"),
		"referrer": "https://www.Example.com/caf",
	}
	if args[0] != "index" || params["class_name"] != "ProductPageView" || len(params["id"].(string)) != 36 {
		t.Fatalf("args = %v", args)
	}
	for k, v := range want {
		if body[k] != v {
			t.Errorf("body[%s] = %#v, want %#v", k, body[k], v)
		}
	}
}

func TestIncrementViewsSkipsSellersAdminsAndBots(t *testing.T) {
	e := newTestEnv(t, true)
	seed(t, e)
	for name, c := range map[string]call{
		"seller": {session: signedInAs(sellerID), csrf: true},
		"admin":  {session: signedInAs(adminID), csrf: true},
		"bot":    {headers: map[string]string{"User-Agent": "Mozilla/5.0 (compatible; Googlebot/2.1)"}},
		"flag":   {json: map[string]any{"user_agent_bot": "1"}, headers: map[string]string{"User-Agent": "x"}},
	} {
		c.method, c.path = "POST", "/links/"+permalink+"/increment_views"
		if c.json == nil {
			c.json = map[string]any{}
		}
		expect(t, e.do(t, c), 200, `{"success":true}`)
		if n := len(jobs(t, e)); n != 0 {
			t.Errorf("%s: %d jobs queued", name, n)
		}
	}
	// A buyer's view counts, with their id.
	e.do(t, call{method: "POST", path: "/links/" + permalink + "/increment_views", session: signedInAs(buyerID), csrf: true, json: map[string]any{}})
	if list := jobs(t, e); len(list) != 1 || list[0]["args"].([]any)[1].(map[string]any)["body"].(map[string]any)["user_id"] != float64(buyerID) {
		t.Errorf("jobs = %v", list)
	}

	w := e.do(t, call{method: "POST", path: "/links/missing-product/increment_views", json: map[string]any{}})
	expect(t, w, 404, `{"status":404,"error":"Not Found"}`)
}

func TestIncrementViewsGifCountsOnlyWithAnAnalyticsToken(t *testing.T) {
	e := newTestEnv(t, true)
	seed(t, e)
	payload, _ := json.Marshal(map[string]any{"product_id": productID, "source_url": "https://example.com/page", "event_id": "evt-1"})
	token := signAnalyticsToken(t, payload, e.now.Add(time.Minute))

	w := e.do(t, call{method: "GET", path: "/links/" + permalink + "/increment_views.gif?analytics_token=" + url.QueryEscape(token),
		headers: map[string]string{"Referer": "https://example.com/page", "Accept": "image/avif,image/webp,*/*"}})
	if w.Code != 200 || w.Body.String() != transparentGIF.Body || w.Header().Get("Content-Type") != "image/gif" || w.Header().Get("Cache-Control") != "no-cache" {
		t.Fatalf("got %d %v", w.Code, w.Header())
	}
	list := jobs(t, e)
	if len(list) != 1 {
		t.Fatalf("jobs = %v", list)
	}
	params := list[0]["args"].([]any)[1].(map[string]any)
	// external_analytics_view_id: one id per landing-page event, so a retried pixel overwrites.
	sum := sha256.Sum256([]byte(strconv.FormatInt(productID, 10) + "\x00evt-1"))
	if params["id"] != hex.EncodeToString(sum[:]) {
		t.Errorf("id = %v", params["id"])
	}
	if body := params["body"].(map[string]any); body["url"] != "https://example.com/page" || body["referrer"] != "https://example.com/page" {
		t.Errorf("body = %v", body)
	}

	// Another referrer, or no token, renders the pixel without counting.
	e.do(t, call{method: "GET", path: "/links/" + permalink + "/increment_views.gif?analytics_token=" + url.QueryEscape(token),
		headers: map[string]string{"Referer": "https://example.com/other"}})
	e.do(t, call{method: "GET", path: "/links/" + permalink + "/increment_views"})
	if n := len(jobs(t, e)); n != 1 {
		t.Errorf("%d jobs", n)
	}
}

func TestTrackUserActionStoresEventsRailsWouldStore(t *testing.T) {
	e := newTestEnv(t, true)
	seed(t, e)
	path := "/links/" + permalink + "/track_user_action"
	ua := map[string]string{"User-Agent": "go-web-beacons-test", "CF-Connecting-IP": "81.2.69.160", "Referer": "https://www.google.com/search"}

	// Anonymous and not a permitted name: dropped. A buyer's: kept. The seller's own: dropped.
	e.do(t, call{method: "POST", path: path, headers: ua, json: map[string]any{"event_name": "share_click"}})
	e.do(t, call{method: "POST", path: path, headers: ua, csrf: true, session: signedInAs(buyerID),
		json: map[string]any{"event_name": "share_click", "was_product_recommended": true, "from_multi_overlay": "true", "is_modal": "false", "view_url": "/l/x"}})
	e.do(t, call{method: "POST", path: path, headers: ua, csrf: true, session: signedInAs(sellerID), json: map[string]any{"event_name": "share_click"}})
	e.do(t, call{method: "POST", path: path, headers: ua, json: map[string]any{"event_name": "product_refund_policy_fine_print_view"}})

	rows, err := e.db.Query(`SELECT event_name, user_id, link_id, price_cents, visit_id, referrer, referrer_domain, view_url, is_modal,
		is_mobile, ip_country, ip_state, ip_latitude FROM events WHERE link_id = ? ORDER BY id`, productID)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var got []string
	for rows.Next() {
		var name, referrer, domain, viewURL string
		var userID sql.NullInt64
		var link, price, flags int64
		var modal sql.NullBool
		var mobile bool
		var country, state sql.NullString
		var lat float64
		rows.Scan(&name, &userID, &link, &price, &flags, &referrer, &domain, &viewURL, &modal, &mobile, &country, &state, &lat)
		got = append(got, strings.Join([]string{name, nullInt(userID), itoa(price), itoa(flags), referrer, domain, viewURL, nullBool(modal), boolString(mobile), country.String, state.String, itoa(int64(lat))}, "|"))
	}
	want := []string{
		"share_click|1500102|500|34|https://www.google.com/search|recommended_by_gumroad|/l/x|false|false|United Kingdom|WBK|0",
		"product_refund_policy_fine_print_view|NULL|500|0|https://www.google.com/search|google.com|" + path + "|NULL|false|United Kingdom|WBK|0",
	}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("events\n got %s\nwant %s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
}

func TestEventsTrackUserActionWritesSignupEventsAndRefusesPurchases(t *testing.T) {
	e := newTestEnv(t, true)
	seed(t, e)
	ua := map[string]string{"User-Agent": "go-web-beacons-test"}
	expect(t, e.do(t, call{method: "POST", path: "/events/track_user_action", headers: ua, json: map[string]any{"event_name": "signup"}}), 200, `{"success":true}`)
	var n int
	e.db.QueryRow(`SELECT COUNT(*) FROM signup_events WHERE browser = 'go-web-beacons-test' AND link_id IS NULL`).Scan(&n)
	if n != 1 {
		t.Errorf("%d signup events", n)
	}
	w := e.do(t, call{method: "POST", path: "/events/track_user_action", headers: ua, json: map[string]any{"event_name": "purchase"}})
	expect(t, w, 422, `{"status":422,"error":"Unprocessable Content"}`)
}

func TestSuspendedUsersGetCheckSuspendedsAnswer(t *testing.T) {
	e := newTestEnv(t, true)
	seed(t, e)
	w := e.do(t, call{method: "POST", path: "/events/track_user_action", csrf: true, session: signedInAs(suspendID), json: map[string]any{"event_name": "x"}})
	expect(t, w, 200, `{"success":false,"error_message":"`+suspendedMessage+`"}`)
	w = e.do(t, call{method: "POST", path: "/events/track_user_action", csrf: true, session: signedInAs(suspendID),
		headers: map[string]string{"Accept": "text/html", "Referer": "https://gumroad.com/l/x"}, json: map[string]any{}})
	if w.Code != 302 || w.Header().Get("Location") != "https://gumroad.com/l/x" {
		t.Errorf("html: %d %v", w.Code, w.Header())
	}
	// media_locations skips check_suspended.
	expect(t, e.do(t, call{method: "POST", path: "/media_locations", csrf: true, session: signedInAs(suspendID), json: map[string]any{}}), 200, `{"success":false}`)
}

func TestInvalidatedSessionsAreSentToLoginOnTheAppHost(t *testing.T) {
	e := newTestEnv(t, true)
	seed(t, e)
	if _, err := e.db.Exec(`UPDATE users SET last_active_sessions_invalidated_at = ? WHERE id = ?`, time.Unix(1_790_000_100, 0).UTC(), buyerID); err != nil {
		t.Fatal(err)
	}
	w := e.do(t, call{method: "POST", path: "/media_locations", csrf: true, session: signedInAs(buyerID), json: map[string]any{}})
	if w.Code != 302 || w.Header().Get("Location") != "https://gumroad.com/login" || w.Body.Len() != 0 {
		t.Fatalf("got %d %v", w.Code, w.Header())
	}
	w = e.do(t, call{method: "POST", path: "/media_locations", host: "gowebbeaconseller.gumroad.com", csrf: true, session: signedInAs(buyerID), json: map[string]any{}})
	expect(t, w, 200, `{"success":false}`)
}

func TestCartItemsCountCountsAliveCartProducts(t *testing.T) {
	e := newTestEnv(t, true)
	seed(t, e)
	now := e.now
	testdb.Insert(t, e.db, "carts", map[string]any{"id": int64(1_500_101), "user_id": buyerID, "created_at": now, "updated_at": now})
	testdb.Insert(t, e.db, "carts", map[string]any{"id": int64(1_500_102), "browser_guid": "guest-guid", "created_at": now, "updated_at": now})
	item := func(id, cart int64, deleted any) {
		testdb.Insert(t, e.db, "cart_products", map[string]any{"id": id, "cart_id": cart, "product_id": id, "price": 100, "quantity": 1,
			"referrer": "", "created_at": now, "updated_at": now, "deleted_at": deleted})
	}
	item(1_500_101, 1_500_101, nil)
	item(1_500_102, 1_500_101, nil)
	item(1_500_103, 1_500_101, now)
	item(1_500_104, 1_500_102, nil)

	json := map[string]string{"Accept": "application/json"}
	expect(t, e.do(t, call{method: "GET", path: "/cart_items_count", session: signedInAs(buyerID), headers: json}), 200, `{"cart_items_count":2}`)
	expect(t, e.do(t, call{method: "GET", path: "/cart_items_count", cookies: map[string]string{"_gumroad_guid": "guest-guid"}, headers: json}), 200, `{"cart_items_count":1}`)
	expect(t, e.do(t, call{method: "GET", path: "/cart_items_count.json", host: "gowebbeaconseller.gumroad.com", cookies: map[string]string{"_gumroad_guid": "other"}}), 200, `{"cart_items_count":0}`)
}

// signAnalyticsToken is Link#analytics_view_token's MessageVerifier#generate.
func signAnalyticsToken(t *testing.T, payload []byte, expiresAt time.Time) string {
	t.Helper()
	secret, err := pbkdf2.Key(sha256.New, testSecretKeyBase, []byte("product_analytics_view"), 1000, 64)
	if err != nil {
		t.Fatal(err)
	}
	envelope := `{"_rails":{"data":` + string(payload) + `,"exp":"` + expiresAt.UTC().Format("2006-01-02T15:04:05.000Z") +
		`","pur":"` + analyticsViewPurpose + `"}}`
	encoded := base64.StdEncoding.EncodeToString([]byte(envelope))
	mac := hmac.New(sha1.New, secret)
	mac.Write([]byte(encoded))
	return encoded + "--" + hex.EncodeToString(mac.Sum(nil))
}

func eventFingerprintFor(ua, plugins string) string {
	sum := md5.Sum([]byte(ua + "," + plugins))
	return hex.EncodeToString(sum[:])
}

func nullInt(v sql.NullInt64) string {
	if !v.Valid {
		return "NULL"
	}
	return itoa(v.Int64)
}

func nullBool(v sql.NullBool) string {
	if !v.Valid {
		return "NULL"
	}
	return boolString(v.Bool)
}

func boolString(b bool) string {
	if b {
		return "true"
	}
	return "false"
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

func TestMobileMediaLocationsRecordsWithAMobileAPIToken(t *testing.T) {
	e := newTestEnv(t, true)
	seed(t, e)
	token := func(id int64, value, scopes string) {
		testdb.Insert(t, e.db, "oauth_access_tokens", map[string]any{"id": id, "resource_owner_id": buyerID, "application_id": 1,
			"token": value, "scopes": scopes, "created_at": e.now.Add(-time.Hour)})
	}
	token(1_500_101, "goweb-beacon-mobile", "mobile_api creator_api")
	token(1_500_102, "goweb-beacon-sales", "view_sales")

	params := e.mediaParams(videoID, map[string]any{"platform": "android", "mobile_token": testMobileToken, "consumed_at": "2015-09-09T17:26:50PDT"})
	w := e.do(t, call{method: "POST", path: "/mobile/media_locations", host: "api.gumroad.com", json: params,
		headers: map[string]string{"Authorization": "Bearer goweb-beacon-sales"}})
	expect(t, w, 403, ``)

	params["access_token"] = "goweb-beacon-mobile"
	w = e.do(t, call{method: "POST", path: "/mobile/media_locations.json", host: "api.gumroad.com", json: params})
	expect(t, w, 200, `{"success":true}`)
	var consumed time.Time
	if err := e.db.QueryRow(`SELECT consumed_at FROM media_locations WHERE purchase_id = ? AND platform = 'android'`, purchaseID).Scan(&consumed); err != nil {
		t.Fatal(err)
	}
	if !consumed.Equal(time.Date(2015, 9, 10, 0, 26, 50, 0, time.UTC)) {
		t.Errorf("consumed_at = %v", consumed)
	}
}

func TestBeaconBodiesPastTheCapAreRefused(t *testing.T) {
	e := newTestEnv(t, false)
	w := e.do(t, call{method: "POST", path: "/media_locations", csrf: true, form: "location=" + strings.Repeat("1", bodyLimit)})
	if w.Code != 413 || w.Body.Len() != 0 {
		t.Fatalf("got %d %q", w.Code, w.Body.String())
	}
}

func TestCartItemsCountSkipsTheLookupForAGuidMintedNow(t *testing.T) {
	// The handle to MySQL fails on use, so a query would be a 500.
	e := newTestEnv(t, false)
	expect(t, e.do(t, call{method: "GET", path: "/cart_items_count.json"}), 200, `{"cart_items_count":0}`)
}

func TestMediaLocationsCastsLocationLikeActiveModel(t *testing.T) {
	e := newTestEnv(t, true)
	seed(t, e)
	// Infinity.to_i's FloatDomainError is rescued to nil, which fails validation.
	w := e.do(t, call{method: "POST", path: "/media_locations", json: e.mediaParams(videoID, map[string]any{"location": json.Number("1e400")})})
	expect(t, w, 422, `{"status":422,"error":"Unprocessable Content"}`)
	// A value past four bytes raises ActiveModel::RangeError on save.
	w = e.do(t, call{method: "POST", path: "/media_locations", json: e.mediaParams(videoID, map[string]any{"location": json.Number("1e20")})})
	expect(t, w, 500, `{"status":500,"error":"Internal Server Error"}`)
	w = e.do(t, call{method: "POST", path: "/media_locations", json: e.mediaParams(videoID, map[string]any{"location": strings.Repeat("9", 5000)})})
	expect(t, w, 500, `{"status":500,"error":"Internal Server Error"}`)
	if readMediaRow(t, e, videoID) != nil {
		t.Fatal("nothing must be stored")
	}
}

func TestMediaLocationsTreatsAStoredNullConsumedAtAsOlder(t *testing.T) {
	e := newTestEnv(t, true)
	seed(t, e)
	testdb.Insert(t, e.db, "media_locations", map[string]any{"id": int64(1_500_101), "url_redirect_id": redirectID, "purchase_id": purchaseID,
		"product_file_id": videoID, "product_id": productID, "platform": "web", "location": 1, "unit": "seconds", "created_at": e.now, "updated_at": e.now})
	w := e.do(t, call{method: "POST", path: "/media_locations", json: e.mediaParams(videoID, nil)})
	expect(t, w, 200, `{"success":true}`)
	if row := readMediaRow(t, e, videoID); row == nil || row.location != 42 {
		t.Fatalf("row = %+v", row)
	}
}

func TestMediaLocationsUpdateKeepsAPositionWrittenSinceTheRead(t *testing.T) {
	e := newTestEnv(t, true)
	seed(t, e)
	stored := time.Date(2026, 11, 2, 9, 30, 0, 0, time.UTC)
	testdb.Insert(t, e.db, "media_locations", map[string]any{"id": int64(1_500_101), "url_redirect_id": redirectID, "purchase_id": purchaseID,
		"product_file_id": videoID, "product_id": productID, "platform": "web", "location": 90, "unit": "seconds",
		"consumed_at": stored, "created_at": e.now, "updated_at": e.now})
	h := &handlers{deps: Deps{DB: e.db}}
	c := &actionContext{ctx: t.Context(), req: &rails.Request{Now: e.now}}
	// What this request read before a newer position landed.
	read := time.Date(2026, 11, 2, 8, 0, 0, 0, time.UTC)
	rows := &mediaLocationRows{locationID: sql.NullInt64{Int64: 1_500_101, Valid: true}, location: sql.NullInt64{Int64: 10, Valid: true},
		unit: sql.NullString{String: "seconds", Valid: true}, consumedAt: &read}
	sent := time.Date(2026, 11, 2, 9, 0, 0, 0, time.UTC)
	redirect := redirectID
	saved, err := h.saveMediaLocation(c, rows, mediaLocationWrite{urlRedirectID: &redirect, purchaseID: purchaseID, productFileID: videoID,
		productID: productID, platform: "web", location: json.Number("20"), consumedAt: &sent, unit: "seconds"})
	if err != nil || saved {
		t.Fatalf("saved %v, %v", saved, err)
	}
	if row := readMediaRow(t, e, videoID); row.location != 90 || !row.consumedAt.Equal(stored) {
		t.Fatalf("row = %+v", row)
	}
}

func TestInvalidatedSessionsOnACustomDomainRunWithoutAUser(t *testing.T) {
	e := newTestEnv(t, true)
	seed(t, e)
	path := "/links/" + permalink + "/increment_views"
	host := "gowebbeacon-shop.example.com"
	// The seller's own view is skipped while the session is live.
	e.do(t, call{method: "POST", path: path, host: host, csrf: true, session: signedInAs(sellerID), json: map[string]any{}})
	if n := len(jobs(t, e)); n != 0 {
		t.Fatalf("%d jobs", n)
	}
	if _, err := e.db.Exec(`UPDATE users SET last_active_sessions_invalidated_at = ? WHERE id = ?`, time.Unix(1_790_000_100, 0).UTC(), sellerID); err != nil {
		t.Fatal(err)
	}
	w := e.do(t, call{method: "POST", path: path, host: host, csrf: true, session: signedInAs(sellerID), json: map[string]any{}})
	expect(t, w, 200, `{"success":true}`)
	list := jobs(t, e)
	if len(list) != 1 || list[0]["args"].([]any)[1].(map[string]any)["body"].(map[string]any)["user_id"] != nil {
		t.Fatalf("jobs = %v", list)
	}
}

func TestHashParamsWhereRailsWantsAStringSkipTheWrite(t *testing.T) {
	e := newTestEnv(t, true)
	seed(t, e)
	ua := map[string]string{"User-Agent": "go-web-beacons-test"}
	hash := map[string]any{"a": "b"}
	for name, params := range map[string]map[string]any{
		"event_name": {"event_name": hash},
		"view_url":   {"event_name": "share_click", "view_url": hash},
		"plugins":    {"event_name": "share_click", "plugins": []any{"x", hash}},
	} {
		w := e.do(t, call{method: "POST", path: "/events/track_user_action", headers: ua, csrf: true, session: signedInAs(buyerID), json: params})
		if w.Code != 200 || w.Body.String() != `{"success":true}` {
			t.Errorf("%s: %d %s", name, w.Code, w.Body.String())
		}
	}
	var n int
	e.db.QueryRow(`SELECT COUNT(*) FROM events WHERE user_id = ?`, buyerID).Scan(&n)
	if n != 0 {
		t.Errorf("%d events stored", n)
	}

	path := "/links/" + permalink + "/increment_views"
	expect(t, e.do(t, call{method: "POST", path: path, json: map[string]any{"plugins": hash}}), 200, `{"success":true}`)
	if n := len(jobs(t, e)); n != 0 {
		t.Errorf("%d jobs", n)
	}
	// Sidekiq's strict args raise on a Parameters view_url.
	expect(t, e.do(t, call{method: "POST", path: path, json: map[string]any{"view_url": hash}}), 500, `{"status":500,"error":"Internal Server Error"}`)
}
