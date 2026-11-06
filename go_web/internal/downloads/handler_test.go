package downloads

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha1"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"

	"github.com/antiwork/gumroad/go_web/internal/inertia"
	"github.com/antiwork/gumroad/go_web/internal/obfuscate"
	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/session"
	"github.com/antiwork/gumroad/go_web/internal/session/sessiontest"
	"github.com/antiwork/gumroad/go_web/internal/session/testdb"
	"github.com/antiwork/gumroad/go_web/internal/web"
)

const (
	testSecretKeyBase = "go-web-downloads-test-secret-key-base"
	sessionName       = "_gumroad_app_session"

	sellerID       = int64(1_780_001)
	buyerID        = int64(1_780_002)
	strangerID     = int64(1_780_003)
	adminID        = int64(1_780_004)
	productID      = int64(1_780_101)
	coffeeID       = int64(1_780_102)
	membershipID   = int64(1_780_103)
	blockingID     = int64(1_780_104)
	purchaseID     = int64(1_780_201)
	fileID         = int64(1_780_301)
	audioID        = int64(1_780_302)
	subscriptionID = int64(1_780_401)
	buyerIP        = "203.0.113.50"
)

var testNow = time.Date(2026, 11, 5, 12, 0, 0, 0, time.UTC)

type testEnv struct {
	t         *testing.T
	db        *sql.DB
	handler   http.Handler
	codec     *session.Codec
	ids       *obfuscate.IDs
	railsHit  *http.Request
	railsBody []byte
}

func newTestEnv(t *testing.T) *testEnv { return newConfiguredTestEnv(t, nil, nil) }

// newTestEnvWithRedis seeds Redis before the app reads it.
func newTestEnvWithRedis(t *testing.T, seed func(*miniredis.Miniredis)) *testEnv {
	return newConfiguredTestEnv(t, seed, nil)
}

// newConfiguredTestEnv lets configure change the Config before the handler is registered.
func newConfiguredTestEnv(t *testing.T, seed func(*miniredis.Miniredis), configure func(*testEnv, *Config)) *testEnv {
	t.Helper()
	db := testdb.Open(t)
	e := &testEnv{t: t, db: db}
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		e.railsHit = r
		e.railsBody, _ = io.ReadAll(r.Body)
		w.Header().Set("X-From", "rails")
		io.WriteString(w, "rails")
	}))
	t.Cleanup(upstream.Close)
	upstreams := filepath.Join(t.TempDir(), "upstreams")
	os.WriteFile(upstreams, []byte(strings.TrimPrefix(upstream.URL, "http://")+"\n"), 0o600)

	env, err := web.LoadEnvironment(func(k string) string {
		return map[string]string{"RAILS_ENV": "production", "REVISION": "test"}[k]
	})
	if err != nil {
		t.Fatal(err)
	}
	e.codec, _ = session.NewCodec(testSecretKeyBase)
	e.ids, _ = obfuscate.New("go-web-downloads-cipher-key", "123456789")
	mr := miniredis.RunT(t)
	if seed != nil {
		seed(mr)
	}
	redisClient := redis.NewClient(&redis.Options{Addr: mr.Addr()})
	app := web.NewApp(env, slog.New(slog.NewTextHandler(io.Discard, nil)), redisClient)
	c := &Config{
		Env:      env,
		DB:       db,
		Stack:    rails.NewStack(env, ""),
		Store:    session.NewStore(e.codec, "production", "https", "", false),
		Resolver: &session.Resolver{Users: &session.Users{DB: db}, Redis: redisClient, Codec: e.codec},
		IDs:      e.ids,
		Proxy:    web.NewRailsProxy(upstreams),
		Meta:     inertia.DefaultMeta{Title: "Gumroad", Environment: "production", AssetHost: "https://assets.gumroad.com", AnalyticsByEnvironment: true},
		Now:      func() time.Time { return testNow },
		// DryRunKey stays unset unless a test turns dry runs on.
		DryRunOnce: redisClient,
	}
	if configure != nil {
		configure(e, c)
	}
	Register(app, c)
	e.handler = app
	e.seed()
	return e
}

func (e *testEnv) seed() {
	t, db := e.t, e.db
	testdb.User(t, db, sellerID, map[string]any{"username": "gowebdownloadseller", "external_id": "1780001"})
	testdb.User(t, db, buyerID, map[string]any{"external_id": "1780002"})
	testdb.User(t, db, strangerID, map[string]any{"external_id": "1780003"})
	testdb.User(t, db, adminID, map[string]any{"flags": 1 | 1<<27, "external_id": "1780004"})
	for id, extra := range map[int64]map[string]any{productID: nil, coffeeID: {"native_type": "coffee"}, membershipID: nil, blockingID: {"flags": 1 << 9}} {
		row := map[string]any{"id": id, "user_id": sellerID, "name": "Download", "unique_permalink": "gowebdl" + strings.TrimPrefix(itoa(id), "1780"), "price_cents": 500}
		for k, v := range extra {
			row[k] = v
		}
		testdb.Insert(t, db, "links", row)
	}
	testdb.Insert(t, db, "product_files", map[string]any{"id": fileID, "link_id": productID, "filetype": "pdf", "filegroup": "document", "pagelength": 10, "position": 0, "created_at": testNow, "updated_at": testNow})
	testdb.Insert(t, db, "product_files", map[string]any{"id": audioID, "link_id": productID, "filetype": "mp3", "filegroup": "audio", "duration": 61, "position": 1, "created_at": testNow, "updated_at": testNow})
	testdb.CleanupWhere(t, db, "purchases", "id BETWEEN ? AND ?", purchaseID, purchaseID+99)
	testdb.CleanupWhere(t, db, "url_redirects", "id BETWEEN ? AND ?", purchaseID, purchaseID+99)
	testdb.CleanupWhere(t, db, "subscriptions", "id BETWEEN ? AND ?", subscriptionID, subscriptionID+99)
	testdb.CleanupWhere(t, db, "media_locations", "purchase_id BETWEEN ? AND ?", purchaseID, purchaseID+99)
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

var nextPurchase = purchaseID

// purchase inserts a purchase of product (buyer as purchaser unless overridden) and its url
// redirect, and returns the token.
func (e *testEnv) purchase(product int64, purchase, redirect map[string]any) string {
	e.t.Helper()
	nextPurchase++
	id := nextPurchase
	row := map[string]any{"id": id, "link_id": product, "seller_id": sellerID, "purchaser_id": buyerID, "ip_address": buyerIP, "purchase_state": "successful"}
	for k, v := range purchase {
		row[k] = v
	}
	testdb.Insert(e.t, e.db, "purchases", row)
	token := "gowebdl" + itoa(id)
	r := map[string]any{"id": id, "purchase_id": id, "token": token, "flags": 1}
	for k, v := range redirect {
		r[k] = v
	}
	testdb.Insert(e.t, e.db, "url_redirects", r)
	return token
}

type call struct {
	token   string
	user    int64
	data    string
	headers map[string]string
	cookies map[string]string
	// encrypted are cookies.encrypted values, as JSON.
	encrypted map[string]any
	// repeat adds a second value for a header.
	repeat map[string]string
	query  string
	host   string
}

func (e *testEnv) poll(c call) *httptest.ResponseRecorder {
	e.t.Helper()
	e.railsHit = nil
	target := "/d/" + c.token
	if c.query != "" {
		target += "?" + c.query
	}
	r := httptest.NewRequest("GET", target, nil)
	r.Host = "gumroad.com"
	if c.host != "" {
		r.Host = c.host
	}
	r.Header.Set("X-Forwarded-Proto", "https")
	r.Header.Set("X-Forwarded-For", buyerIP)
	r.RemoteAddr = "10.1.0.9:5000"
	r.Header.Set("Accept", "text/html, application/xhtml+xml")
	r.Header.Set("X-Requested-With", "XMLHttpRequest")
	r.Header.Set("X-Inertia", "true")
	r.Header.Set("X-Inertia-Partial-Component", "UrlRedirects/DownloadPage")
	data := c.data
	if data == "" {
		data = "latest_media_locations"
	}
	r.Header.Set("X-Inertia-Partial-Data", data)
	for k, v := range c.headers {
		r.Header.Set(k, v)
	}
	for k, v := range c.repeat {
		r.Header.Add(k, v)
	}
	var cookies []string
	if c.user != 0 {
		// In the order Devise and the CSRF commit leave a signed-in session.
		raw := []byte(rails.EncodeJSON(rails.NewRHash().
			Str("session_id", "0123456789abcdef0123456789abcdef").
			Str("warden.user.user.key", []any{[]any{c.user}, "salt"}).
			Str("warden.user.user.session", rails.NewRHash().Str("last_sign_in_at", testNow.Unix())).
			Str("_csrf_token", session.GenerateCSRFToken())))
		cookies = append(cookies, sessionName+"="+url.QueryEscape(sessiontest.Encrypt(e.t, testSecretKeyBase, sessionName, raw, testNow.Add(time.Hour))))
	}
	for k, v := range c.cookies {
		cookies = append(cookies, k+"="+url.QueryEscape(v))
	}
	for k, v := range c.encrypted {
		raw, _ := json.Marshal(v)
		cookies = append(cookies, k+"="+url.QueryEscape(sessiontest.Encrypt(e.t, testSecretKeyBase, k, raw, time.Time{})))
	}
	if len(cookies) > 0 {
		r.Header.Set("Cookie", strings.Join(cookies, "; "))
	}
	w := httptest.NewRecorder()
	e.handler.ServeHTTP(w, r)
	return w
}

// sessionAfter decrypts the session cookie the response set.
func (e *testEnv) sessionAfter(w *httptest.ResponseRecorder) *rails.Hash {
	e.t.Helper()
	for _, line := range w.Header().Values("Set-Cookie") {
		if !strings.HasPrefix(line, sessionName+"=") {
			continue
		}
		value, _ := url.QueryUnescape(strings.SplitN(strings.TrimPrefix(line, sessionName+"="), ";", 2)[0])
		raw, ok := e.codec.Decrypt(sessionName, value, testNow)
		if !ok {
			e.t.Fatalf("the session cookie does not decrypt: %s", line)
		}
		v, _ := rails.ParseJSON(raw)
		return v.(*rails.Hash)
	}
	return nil
}

func cookieNames(w *httptest.ResponseRecorder) []string {
	var names []string
	for _, line := range w.Header().Values("Set-Cookie") {
		names = append(names, strings.SplitN(line, "=", 2)[0])
	}
	return names
}

func TestPurchasersPollTheirFilesPositions(t *testing.T) {
	e := newTestEnv(t)
	token := e.purchase(productID, nil, nil)
	testdb.Insert(t, e.db, "media_locations", map[string]any{"id": int64(1_780_501), "product_file_id": fileID, "url_redirect_id": nextPurchase,
		"purchase_id": nextPurchase, "product_id": productID, "location": 4, "unit": "page_number", "platform": "web", "consumed_at": testNow.Add(-time.Hour),
		"created_at": testNow, "updated_at": testNow})

	w := e.poll(call{token: token, user: buyerID, data: "latest_media_locations,audio_durations"})
	if e.railsHit != nil || w.Code != 200 {
		t.Fatalf("%d, Rails hit %v: %s", w.Code, e.railsHit != nil, w.Body.String())
	}
	var body struct {
		Component string
		Props     map[string]json.RawMessage
		URL       string
		Version   *string
	}
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	file, audio := e.ids.Encrypt(fileID), e.ids.Encrypt(audioID)
	wantProps := `{"errors":{},"audio_durations":{"` + audio + `":61},"latest_media_locations":{"` + file + `":{"location":4,"unit":"page_number","timestamp":"2026-11-05T11:00:00Z"},"` + audio + `":null},"_inertia_meta":`
	if !strings.Contains(w.Body.String(), wantProps) || body.Component != "UrlRedirects/DownloadPage" || body.URL != "/d/"+token || body.Version != nil {
		t.Errorf("body %s\nwant props starting %s", w.Body.String(), wantProps)
	}
	if !strings.HasSuffix(w.Body.String(), `"url":"/d/`+token+`","version":null,"encryptHistory":false,"clearHistory":false}`) {
		t.Errorf("page object tail: %s", w.Body.String())
	}
	h := w.Header()
	if h.Get("X-Inertia") != "true" || h.Get("Vary") != "X-Inertia, Origin" || h.Get("X-Robots-Tag") != "noindex" ||
		h.Get("Content-Type") != "application/json; charset=utf-8" || h.Get("Cache-Control") != "max-age=0, private, must-revalidate" ||
		h.Get("ETag") != web.ETag(w.Body.String()) || h.Get("Strict-Transport-Security") != "max-age=31536000" {
		t.Errorf("headers %v", h)
	}
	if names := cookieNames(w); strings.Join(names, ",") != "_gumroad_guid,XSRF-TOKEN,"+sessionName {
		t.Errorf("cookies %v", names)
	}
	s := e.sessionAfter(w)
	if strings.Join(s.Keys(), ",") != "session_id,warden.user.user.key,warden.user.user.session,_csrf_token,recommender_model_name" {
		t.Errorf("session keys %v", s.Keys())
	}
	for _, line := range h.Values("Set-Cookie") {
		if strings.HasPrefix(line, "XSRF-TOKEN=") {
			masked, _ := url.QueryUnescape(strings.SplitN(strings.TrimPrefix(line, "XSRF-TOKEN="), ";", 2)[0])
			if !session.ValidAuthenticityToken(s.Value("_csrf_token").(string), masked, "/x", "POST") || !strings.HasSuffix(line, "; path=/; samesite=lax; secure; HttpOnly") {
				t.Errorf("XSRF-TOKEN %q must be a masked token for the session", line)
			}
		}
	}
	if !strings.Contains(w.Body.String(), `"property":"gr:logged_in_user:id","content":"1780002"`) {
		t.Errorf("the meta tags name the signed-in user: %s", w.Body.String())
	}
}

func TestANewVisitorGetsASessionInRailsOrder(t *testing.T) {
	e := newTestEnv(t)
	token := e.purchase(productID, nil, map[string]any{"flags": 0})
	w := e.poll(call{token: token, headers: map[string]string{"Referer": "https://Example.org/x"}})
	if w.Code != 200 || e.railsHit != nil {
		t.Fatalf("an unseen redirect is open to anyone: %d %s", w.Code, w.Body.String())
	}
	s := e.sessionAfter(w)
	if strings.Join(s.Keys(), ",") != "session_id,signup_referrer,recommender_model_name,_csrf_token" || s.Value("signup_referrer") != "example.org" {
		t.Errorf("session %s", rails.EncodeJSON(s))
	}
	if !strings.Contains(w.Body.String(), `"property":"gr:logged_in_user:id"}`) {
		t.Errorf("a blank user id is dropped from the tag: %s", w.Body.String())
	}
}

func TestAccessChecksRedirectLikeRails(t *testing.T) {
	e := newTestEnv(t)
	lapsed, blocked, plan := subscriptionID+1, subscriptionID+2, subscriptionID+3
	for id, row := range map[int64]map[string]any{
		lapsed:  {"link_id": membershipID, "cancelled_at": testNow.Add(-time.Hour)},
		blocked: {"link_id": blockingID, "cancelled_at": testNow.Add(-time.Hour)},
		plan:    {"link_id": membershipID, "failed_at": testNow.Add(-time.Hour), "flags": 1 << 6},
	} {
		row["id"], row["user_id"], row["created_at"], row["updated_at"] = id, buyerID, testNow, testNow
		testdb.Insert(t, e.db, "subscriptions", row)
	}
	for _, c := range []struct {
		name            string
		purchase, redir map[string]any
		user            int64
		cookies         map[string]string
		product         int64
		wantStatus      int
		wantLocation    string // with <T> for the token
		wantNoCookies   bool
	}{
		{name: "refunded", purchase: map[string]any{"stripe_refunded": true}, user: buyerID, wantStatus: 302, wantLocation: "https://gumroad.com/r/<T>/expired"},
		{name: "chargeback", purchase: map[string]any{"chargeback_date": testNow}, user: buyerID, wantStatus: 302, wantLocation: "https://gumroad.com/r/<T>/expired"},
		{name: "chargeback reversed", purchase: map[string]any{"chargeback_date": testNow, "flags": 1 << 9}, user: buyerID, wantStatus: 200},
		{name: "zero chargeback date", purchase: map[string]any{"chargeback_date": "0000-00-00 00:00:00"}, user: buyerID, wantStatus: 200},
		{name: "another user", user: strangerID, wantStatus: 302, wantLocation: "https://gumroad.com/r/<T>/check_purchaser?next=%2Fd%2F<T>"},
		{name: "rental expired", purchase: map[string]any{"rental_expired": true}, user: buyerID, wantStatus: 302, wantLocation: "https://gumroad.com/r/<T>/rental_expired"},
		{name: "access revoked", purchase: map[string]any{"flags": 1 << 24}, user: buyerID, wantStatus: 302, wantLocation: "https://gumroad.com/r/<T>/expired"},
		{name: "lapsed membership that keeps access", product: membershipID, purchase: map[string]any{"subscription_id": lapsed}, user: buyerID, wantStatus: 200},
		{name: "lapsed membership that blocks access", product: blockingID, purchase: map[string]any{"subscription_id": blocked}, user: buyerID, wantStatus: 302, wantLocation: "https://gumroad.com/r/<T>/membership_inactive"},
		{name: "failed installment plan", product: membershipID, purchase: map[string]any{"subscription_id": plan}, user: buyerID, wantStatus: 302, wantLocation: "https://gumroad.com/r/<T>/membership_inactive"},
		{name: "seen, signed out, another IP", purchase: map[string]any{"ip_address": "198.51.100.1"}, wantStatus: 302, wantLocation: "https://gumroad.com/confirm?destination=download_page&id=<T>"},
		{name: "seen, signed out, the buyer's IP", wantStatus: 200},
		{name: "test purchase, signed out", purchase: map[string]any{"purchaser_id": sellerID}, wantStatus: 302, wantLocation: "https://gumroad.com/login?next=%2Fd%2F<T>"},
		{name: "test purchase, the seller", purchase: map[string]any{"purchaser_id": sellerID}, user: sellerID, wantStatus: 200},
		{name: "test purchase, someone else", purchase: map[string]any{"purchaser_id": sellerID}, user: buyerID, wantStatus: 404, wantNoCookies: true},
		{name: "guest purchase, signed in, another IP", purchase: map[string]any{"purchaser_id": nil, "ip_address": "198.51.100.1"}, user: strangerID, wantStatus: 302, wantLocation: "https://gumroad.com/confirm?destination=download_page&id=<T>"},
	} {
		t.Run(c.name, func(t *testing.T) {
			product := c.product
			if product == 0 {
				product = productID
			}
			token := e.purchase(product, c.purchase, c.redir)
			w := e.poll(call{token: token, user: c.user, cookies: c.cookies})
			if e.railsHit != nil {
				t.Fatal("handed to Rails")
			}
			want := strings.ReplaceAll(c.wantLocation, "<T>", token)
			if w.Code != c.wantStatus || w.Header().Get("Location") != want {
				t.Fatalf("%d %q, want %d %q", w.Code, w.Header().Get("Location"), c.wantStatus, want)
			}
			if c.wantNoCookies != (len(w.Header().Values("Set-Cookie")) == 0) {
				t.Errorf("cookies %v", cookieNames(w))
			}
			if w.Code == 302 && (strings.Join(cookieNames(w), ",") != "_gumroad_guid,"+sessionName || w.Body.Len() != 0 || w.Header().Get("X-Robots-Tag") != "" ||
				w.Header().Get("Strict-Transport-Security") != "max-age=31536000") {
				t.Errorf("a filter's redirect: cookies %v, body %q, headers %v", cookieNames(w), w.Body.String(), w.Header())
			}
		})
	}
}

func TestPollsRailsKeepsAreHandedToRails(t *testing.T) {
	e := newTestEnv(t)
	coffee := e.purchase(coffeeID, nil, nil)
	bundle := e.purchase(productID, map[string]any{"flags": 1 << 25}, nil)
	plain := e.purchase(productID, nil, nil)
	for _, c := range []struct {
		name string
		call call
	}{
		{"team member", call{token: plain, user: adminID}},
		{"remember me", call{token: plain, cookies: map[string]string{"remember_user_token": "x"}}},
		{"mobile web view", call{token: plain, query: "access_token=x&mobile_token=y"}},
		{"coffee", call{token: coffee, user: buyerID}},
		{"bundle", call{token: bundle, user: buyerID}},
		{"not a poll", call{token: plain, user: buyerID, data: "files"}},
		{"version", call{token: plain, user: buyerID, headers: map[string]string{"X-Inertia-Version": "1"}}},
		{"seller subdomain", call{token: plain, user: buyerID, host: "gowebdownloadseller.gumroad.com"}},
		{"format", call{token: plain, user: buyerID, query: "format=json"}},
		{"bearer token", call{token: plain, headers: map[string]string{"Authorization": "Bearer x"}}},
		{"bearer_token param", call{token: plain, query: "bearer_token=x"}},
		{"partial except", call{token: plain, user: buyerID, headers: map[string]string{"X-Inertia-Partial-Except": "a"}}},
		{"error bag", call{token: plain, user: buyerID, headers: map[string]string{"X-Inertia-Error-Bag": "a"}}},
		{"empty partial data", call{token: plain, user: buyerID, data: ","}},
		{"repeated partial data", call{token: plain, user: buyerID, repeat: map[string]string{"X-Inertia-Partial-Data": "audio_durations"}}},
		{"spoofed IP", call{token: plain, user: buyerID, headers: map[string]string{"Client-Ip": "198.51.100.7"}}},
		{"rotated confirmed_redirect cookie", call{token: plain, cookies: map[string]string{"confirmed_redirect": oldKeyCookie(t, "confirmed_redirect", `"`+plain+`"`)}}},
		{"format suffix", call{token: plain + ".json", user: buyerID}},
	} {
		t.Run(c.name, func(t *testing.T) {
			w := e.poll(c.call)
			if e.railsHit == nil || w.Body.String() != "rails" || w.Header().Get("X-From") != "rails" || w.Header().Get("X-Revision") != "" {
				t.Fatalf("%d %q %v: want Rails' response", w.Code, w.Body.String(), w.Header())
			}
		})
	}
}

func TestAnUnknownTokenIsAnExceptionWithNoCookies(t *testing.T) {
	e := newTestEnv(t)
	w := e.poll(call{token: "nosuchgowebtoken", user: buyerID})
	if w.Code != 404 || len(w.Header().Values("Set-Cookie")) != 0 || !strings.Contains(w.Body.String(), "<html") {
		t.Errorf("%d %v %q", w.Code, w.Header(), w.Body.String()[:min(80, w.Body.Len())])
	}
}

func TestTheOtherWaysIntoAPurchase(t *testing.T) {
	e := newTestEnv(t)
	sub := subscriptionID + 10
	testdb.Insert(t, e.db, "subscriptions", map[string]any{"id": sub, "link_id": membershipID, "user_id": strangerID, "created_at": testNow, "updated_at": testNow})
	importedID := int64(1_780_601)
	testdb.Insert(t, e.db, "imported_customers", map[string]any{"id": importedID, "link_id": productID, "email": "buyer@example.com",
		"created_at": testNow, "updated_at": testNow})
	otherIP := map[string]any{"ip_address": "198.51.100.1"}

	confirmed := e.purchase(productID, otherIP, nil)
	if w := e.poll(call{token: confirmed, encrypted: map[string]any{"confirmed_redirect": confirmed}}); w.Code != 200 || e.railsHit != nil {
		t.Errorf("the confirmed_redirect cookie lets the poll through: %d", w.Code)
	}
	wrongCookie := e.purchase(productID, otherIP, nil)
	if w := e.poll(call{token: wrongCookie, encrypted: map[string]any{"confirmed_redirect": confirmed}}); w.Code != 302 {
		t.Errorf("a cookie for another token does not: %d", w.Code)
	}
	imported := e.purchase(productID, otherIP, map[string]any{"imported_customer_id": importedID})
	if w := e.poll(call{token: imported}); w.Code != 200 || e.railsHit != nil {
		t.Errorf("an imported customer's redirect: %d", w.Code)
	}
	displayed := e.purchase(productID, otherIP, nil)
	w := e.poll(call{token: displayed, query: "display=mobile_app"})
	if want := "https://gumroad.com/confirm?destination=download_page&display=mobile_app&id=" + displayed; w.Code != 302 || w.Header().Get("Location") != want {
		t.Errorf("display rides along to /confirm: %d %q", w.Code, w.Header().Get("Location"))
	}
	if !strings.Contains(e.sessionAfter(w).Value("recommender_model_name").(string), "sales") {
		t.Error("a redirect still commits the session")
	}
	owned := e.purchase(membershipID, map[string]any{"subscription_id": sub}, nil)
	if e.poll(call{token: owned, user: strangerID}); e.railsHit == nil {
		t.Error("the subscription's owner viewing another purchaser's renewal is Rails'")
	}
}

func TestAnInvalidCurrentSellerCookieIsDeletedFirst(t *testing.T) {
	e := newTestEnv(t)
	token := e.purchase(productID, nil, nil)
	w := e.poll(call{token: token, user: buyerID, encrypted: map[string]any{"current_seller_id": sellerID}})
	lines := w.Header().Values("Set-Cookie")
	if w.Code != 200 || len(lines) != 4 || !strings.HasPrefix(lines[0], "current_seller_id=; domain=gumroad.com; path=/; max-age=0; expires=Thu, 01 Jan 1970 00:00:00 GMT") {
		t.Errorf("%d %q", w.Code, lines)
	}
}

func TestACustomSubdomainRedirectRunsAfterTheMetaTags(t *testing.T) {
	// The next purchase's token, which the table has to name before the app loads it.
	token := "gowebdl" + itoa(nextPurchase+1)
	e := newTestEnvWithRedis(t, func(mr *miniredis.Miniredis) {
		mr.Set("subdomain_redirect_namespace:subdomain_redirects_config", "gumroad.com/d/"+token+"=https://example.com/elsewhere")
	})
	if got := e.purchase(productID, nil, nil); got != token {
		t.Fatalf("token %s, expected %s", got, token)
	}
	w := e.poll(call{token: token, user: buyerID})
	if w.Code != 302 || w.Header().Get("Location") != "https://example.com/elsewhere" || e.railsHit != nil {
		t.Fatalf("%d %q", w.Code, w.Header().Get("Location"))
	}
	if names := cookieNames(w); strings.Join(names, ",") != sessionName || e.sessionAfter(w).Value("recommender_model_name") != nil {
		t.Errorf("the redirect comes before set_gumroad_guid and set_recommender_model_name: %v", names)
	}
}

func TestAGetWithABodyIsRails(t *testing.T) {
	e := newTestEnv(t)
	token := e.purchase(productID, nil, nil)
	r := httptest.NewRequest("GET", "/d/"+token, strings.NewReader(`{"access_token":"x"}`))
	r.Host = "gumroad.com"
	for k, v := range map[string]string{"X-Forwarded-Proto": "https", "Content-Type": "application/json", "X-Inertia": "true",
		"X-Inertia-Partial-Component": "UrlRedirects/DownloadPage", "X-Inertia-Partial-Data": "audio_durations"} {
		r.Header.Set(k, v)
	}
	w := httptest.NewRecorder()
	e.handler.ServeHTTP(w, r)
	if e.railsHit == nil || w.Body.String() != "rails" {
		t.Fatalf("%d %q", w.Code, w.Body.String())
	}
	if string(e.railsBody) != `{"access_token":"x"}` {
		t.Errorf("Rails got body %q", e.railsBody)
	}
}

func TestAMissingProductRaisesWhereRailsReadsIt(t *testing.T) {
	e := newTestEnv(t)
	orphan := e.purchase(productID, map[string]any{"link_id": int64(1_789_999)}, nil)
	if w := e.poll(call{token: orphan, user: buyerID}); w.Code != 500 {
		t.Errorf("is_test_purchase? raises on a purchase with no product: %d", w.Code)
	}
	refunded := e.purchase(productID, map[string]any{"link_id": int64(1_789_999), "stripe_refunded": true}, nil)
	if w := e.poll(call{token: refunded, user: buyerID}); w.Code != 302 {
		t.Errorf("a refund redirects before anything reads the product: %d", w.Code)
	}
	sub := subscriptionID + 20
	testdb.Insert(t, e.db, "subscriptions", map[string]any{"id": sub, "link_id": int64(1_789_998), "user_id": buyerID, "created_at": testNow, "updated_at": testNow})
	alive := e.purchase(productID, map[string]any{"subscription_id": sub}, nil)
	if w := e.poll(call{token: alive, user: buyerID}); w.Code != 200 {
		t.Errorf("an alive subscription never reads its product: %d", w.Code)
	}
}

// oldKeyCookie seals value under cookie_rotator.rb's SHA1-derived key, which Rails still reads.
func oldKeyCookie(t *testing.T, name, value string) string {
	t.Helper()
	key, _ := pbkdf2.Key(sha1.New, testSecretKeyBase, []byte("authenticated encrypted cookie"), 1000, 32)
	block, _ := aes.NewCipher(key)
	aead, _ := cipher.NewGCM(block)
	envelope := `{"_rails":{"message":"` + base64.StdEncoding.EncodeToString([]byte(value)) + `","exp":null,"pur":"cookie.` + name + `"}}`
	iv := make([]byte, aead.NonceSize())
	rand.Read(iv)
	return rails.JoinEncryptedMessage(aead.Seal(nil, iv, []byte(envelope), nil), iv)
}

func TestMissingProductsAndZeroDatesBehaveAsInRails(t *testing.T) {
	e := newTestEnv(t)
	gone := int64(1_789_997)
	lapsed := subscriptionID + 30
	testdb.Insert(t, e.db, "subscriptions", map[string]any{"id": lapsed, "link_id": gone, "user_id": buyerID, "cancelled_at": testNow.Add(-time.Hour),
		"created_at": testNow, "updated_at": testNow})
	if w := e.poll(call{token: e.purchase(productID, map[string]any{"subscription_id": lapsed}, nil), user: buyerID}); w.Code != 500 {
		t.Errorf("a lapsed subscription reads its missing product and raises: %d", w.Code)
	}
	rental := e.purchase(productID, map[string]any{"link_id": gone, "rental_expired": true}, nil)
	if w := e.poll(call{token: rental}); w.Code != 302 || !strings.HasSuffix(w.Header().Get("Location"), "/rental_expired") {
		t.Errorf("signed out, the rental check comes before anything reads the product: %d %q", w.Code, w.Header().Get("Location"))
	}
	if w := e.poll(call{token: rental, user: strangerID}); w.Code != 500 {
		t.Errorf("signed in as someone else, the purchaser check reads is_test_purchase? first: %d", w.Code)
	}
	zero := subscriptionID + 31
	testdb.Insert(t, e.db, "subscriptions", map[string]any{"id": zero, "link_id": blockingID, "user_id": buyerID, "cancelled_at": "0000-00-00 00:00:00",
		"failed_at": "0000-00-00 00:00:00", "ended_at": "0000-00-00 00:00:00", "created_at": testNow, "updated_at": testNow})
	if w := e.poll(call{token: e.purchase(blockingID, map[string]any{"subscription_id": zero}, nil), user: buyerID}); w.Code != 200 {
		t.Errorf("zero dates are nil, so the subscription is alive: %d", w.Code)
	}
}

func TestHSTSIsForTheAppDomainsRespondedPages(t *testing.T) {
	e := newTestEnv(t)
	token := e.purchase(productID, nil, nil)
	if w := e.poll(call{token: token, user: buyerID, host: "app.gumroad.com"}); w.Code != 200 || w.Header().Get("Strict-Transport-Security") != "" {
		t.Errorf("app.gumroad.com: %d %q", w.Code, w.Header().Get("Strict-Transport-Security"))
	}
	if w := e.poll(call{token: "nosuchgowebtoken", user: buyerID}); w.Code != 404 || w.Header().Get("Strict-Transport-Security") != "" {
		t.Errorf("an exception: %d %q", w.Code, w.Header().Get("Strict-Transport-Security"))
	}
}

func TestAPositionsPollWithoutAPurchaseReadsNoFiles(t *testing.T) {
	e := newTestEnv(t)
	imported := int64(1_780_602)
	testdb.Insert(t, e.db, "imported_customers", map[string]any{"id": imported, "link_id": productID, "email": "buyer@example.com", "created_at": testNow, "updated_at": testNow})
	// A page the file lookup can't read, as Ruby couldn't: only reading the files would fail.
	testdb.Insert(t, e.db, "rich_contents", map[string]any{"id": int64(1_780_701), "entity_id": productID, "entity_type": "Link",
		"description": `{"not":"a list of nodes"}`, "created_at": testNow, "updated_at": testNow})
	// A purchase id that points nowhere, so url_redirect.purchase is nil.
	token := e.purchase(productID, nil, map[string]any{"purchase_id": int64(1_789_996), "imported_customer_id": imported})
	w := e.poll(call{token: token})
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"latest_media_locations":{}`) {
		t.Errorf("%d %s", w.Code, w.Body.String())
	}
}
