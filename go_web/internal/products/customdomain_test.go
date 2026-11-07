package products

import (
	"database/sql"
	"fmt"
	"html"
	"io"
	"maps"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"

	"github.com/antiwork/gumroad/go_web/internal/elastic"
	"github.com/antiwork/gumroad/go_web/internal/session/testdb"
	"github.com/antiwork/gumroad/go_web/internal/sidekiq"
)

// customDomainHeaders are how a custom domain's request reaches the web tier: plain http on
// port 80, with the client's IP in CF-Connecting-IP.
func customDomainHeaders(extra map[string]string) map[string]string {
	h := map[string]string{"X-Forwarded-Proto": "http", "X-Forwarded-Port": "80", "CF-Connecting-IP": "203.0.113.9"}
	maps.Copy(h, extra)
	return h
}

func addCustomDomain(t *testing.T, conn *sql.DB, id int64, domain string, columns map[string]any) {
	row := map[string]any{"id": id, "domain": domain, "user_id": sellerID, "state": "verified", "created_at": testNow, "updated_at": testNow}
	maps.Copy(row, columns)
	testdb.Insert(t, conn, "custom_domains", row)
}

// The seller's own custom domain renders their product as their subdomain does, with the
// domain in the canonical URL and the byline. Over http no session cookie is written, and the
// guid cookie isn't secure.
func TestASellersCustomDomain(t *testing.T) {
	for _, c := range []struct{ domain, host string }{
		{"shop.example.com", "shop.example.com"},
		// find_by_host reads an apex or www host as either record, the apex's first.
		{"example.com", "www.example.com"},
		{"www.example.com", "example.com"},
	} {
		t.Run(c.host, func(t *testing.T) {
			e := newTestEnv(t)
			conn := testdb.Open(t)
			addCustomDomain(t, conn, 1_799_501, c.domain, nil)
			w := e.get(c.host, "/l/guide", customDomainHeaders(nil))
			if w.Code != http.StatusOK || e.railsHit != nil {
				t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
			}
			body := w.Body.String()
			seller := pageProps(t, body)["product"].(map[string]any)["seller"].(map[string]any)
			if seller["profile_url"] != "https://"+c.host+"/" {
				t.Errorf("profile_url %v", seller["profile_url"])
			}
			canonical := "https://" + c.host + "/l/guide"
			for _, want := range []string{`<link rel="canonical" href="` + canonical + `"`, `content="` + canonical + `"`,
				`"url":"` + canonical + `"`} {
				if !strings.Contains(body, want) {
					t.Errorf("missing %s", want)
				}
			}
			cookies := w.Header().Values("Set-Cookie")
			if len(cookies) != 2 || !strings.HasPrefix(cookies[0], "_gumroad_guid=") || !strings.Contains(cookies[0], "example.com;") ||
				!strings.HasPrefix(cookies[1], "XSRF-TOKEN=") || strings.Contains(strings.ToLower(strings.Join(cookies, "\n")), "secure") {
				t.Errorf("cookies %v", cookies)
			}
			if w.Header().Get("Strict-Transport-Security") != "" {
				t.Error("HSTS on a custom domain")
			}
			// The offer code's path renders too.
			if w := e.get(c.host, "/l/guide/save10", customDomainHeaders(nil)); w.Code != http.StatusOK || e.railsHit != nil {
				t.Errorf("code path: %d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
			}

			// check_if_needs_redirect stays on the host, over https as short_link_url builds it.
			w = e.get(c.host, "/l/gowebp1?x=1", customDomainHeaders(nil))
			if w.Code != http.StatusMovedPermanently || w.Header().Get("Location") != "https://"+c.host+"/l/guide?x=1" {
				t.Errorf("%d %q", w.Code, w.Header().Get("Location"))
			}
		})
	}
}

// What this port leaves to Rails on a custom domain, and an http request on a subdomain.
func TestACustomDomainThisPortLeavesToRails(t *testing.T) {
	const shop = "shop.example.com"
	for _, c := range []struct {
		name, host, reason string
		headers            map[string]string
		setup              func(t *testing.T, conn *sql.DB)
	}{
		{name: "no domain", reason: "no custom domain"},
		// fetch_leniently finds no alive product, so Rails looks the path up among every seller's.
		{name: "a deleted product's domain", reason: "product custom domain without an alive product", setup: func(t *testing.T, conn *sql.DB) {
			addCustomDomain(t, conn, 1_799_511, shop, map[string]any{"user_id": nil, "product_id": productID})
			mustExec(t, conn, "UPDATE links SET deleted_at = ? WHERE id = ?", testNow, productID)
		}},
		{name: "a domain with a product and a user", reason: "custom domain with a product and a user", setup: func(t *testing.T, conn *sql.DB) {
			addCustomDomain(t, conn, 1_799_511, shop, map[string]any{"product_id": productID})
		}},
		{name: "two rows for the domain", reason: "several custom domains for the host", setup: func(t *testing.T, conn *sql.DB) {
			addCustomDomain(t, conn, 1_799_511, shop, nil)
			addCustomDomain(t, conn, 1_799_512, "SHOP.example.com", nil)
		}},
		// Subdomain.subdomain_request?'s unescaped dots take this for a seller's subdomain.
		{name: "a host Rails reads as a subdomain", host: "mygumroad.com", reason: "host"},
		// Rack::SSL redirects the raw gumroad.com Host to https before routing.
		{name: "a forwarded host behind gumroad.com", host: "gumroad.com", reason: "host",
			headers: map[string]string{"X-Forwarded-Host": shop}},
		{name: "https", reason: "not ssl", headers: map[string]string{"X-Forwarded-Proto": "https", "X-Forwarded-Port": "443"}},
		// Rack takes the last entry, SecureHeaders the first.
		{name: "a forwarded https after http", reason: "not ssl", headers: map[string]string{"X-Forwarded-Proto": "http, https"}},
		{name: "X-Forwarded-Ssl", reason: "forwarded scheme", headers: map[string]string{"X-Forwarded-Ssl": "on"}},
		{name: "another port", reason: "port", headers: map[string]string{"X-Forwarded-Port": "8080"}},
		{name: "a subdomain over http", host: host, reason: "not ssl"},
	} {
		t.Run(c.name, func(t *testing.T) {
			e := newTestEnv(t)
			conn := testdb.Open(t)
			if c.setup != nil {
				c.setup(t, conn)
			}
			target := c.host
			if target == "" {
				target = shop
			}
			headers := customDomainHeaders(c.headers)
			maps.Copy(headers, e.dryRun(target, "/l/guide", testNow))
			w := e.get(target, "/l/guide", headers)
			if w.Code != http.StatusNoContent || w.Header().Get("X-Go-Web-Fallback") != c.reason || e.railsHit != nil {
				t.Errorf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
			}
		})
	}
}

// ensure_seller_is_not_deleted 404s a deleted seller's product on their domain or the product's,
// unless track_utm_link_visit could record a visit first.
func TestADeletedSellersCustomDomain(t *testing.T) {
	const shop, utm = "shop.example.com", "/l/guide?utm_source=a&utm_medium=b&utm_campaign=c"
	sellers := func(t *testing.T, conn *sql.DB) { addCustomDomain(t, conn, 1_799_511, shop, nil) }
	products := func(t *testing.T, conn *sql.DB) {
		addCustomDomain(t, conn, 1_799_511, shop, map[string]any{"user_id": nil, "product_id": productID})
	}
	for _, c := range []struct {
		name, target, reason string
		setup                func(t *testing.T, conn *sql.DB)
	}{
		{name: "the seller's domain", target: "/l/guide", setup: sellers},
		{name: "the product's domain", target: "/l/guide", setup: products},
		{name: "the product's domain with UTM params", target: utm, setup: products},
		{name: "the seller's domain with UTM params", target: utm, setup: sellers, reason: "utm visit for a deleted seller"},
	} {
		t.Run(c.name, func(t *testing.T) {
			e := newTestEnv(t)
			jobs := sidekiqJobs(t, e)
			conn := testdb.Open(t)
			c.setup(t, conn)
			mustExec(t, conn, "UPDATE users SET deleted_at = ? WHERE id = ?", testNow, sellerID)
			headers := customDomainHeaders(nil)
			if c.reason != "" {
				maps.Copy(headers, e.dryRun(shop, c.target, testNow))
			}
			w := e.get(shop, c.target, headers)
			if c.reason != "" {
				if w.Code != http.StatusNoContent || w.Header().Get("X-Go-Web-Fallback") != c.reason {
					t.Errorf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
				}
				return
			}
			if w.Code != http.StatusNotFound || e.railsHit != nil {
				t.Errorf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
			}
			// Nor is a UTM visit recorded on a product's domain.
			for _, queue := range []string{"queue:default", "queue:low"} {
				if queued, _ := jobs.List(queue); len(queued) != 0 {
					t.Errorf("%s %v", queue, queued)
				}
			}
		})
	}
}

// Under a private suffix, the gem's list decides what the apex is: here goweb.myshopify.com,
// whose www host reads it.
func TestACustomDomainUnderAPrivateSuffix(t *testing.T) {
	e := newTestEnv(t)
	conn := testdb.Open(t)
	addCustomDomain(t, conn, 1_799_501, "goweb.myshopify.com", nil)
	w := e.get("www.goweb.myshopify.com", "/l/guide", customDomainHeaders(nil))
	if w.Code != http.StatusOK || e.railsHit != nil {
		t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
	if canonical := `<link rel="canonical" href="https://www.goweb.myshopify.com/l/guide"`; !strings.Contains(w.Body.String(), canonical) {
		t.Errorf("missing %s", canonical)
	}
}

// find_by_host tries the apex before www, whichever seller owns each.
func TestTheApexDomainWinsOverWww(t *testing.T) {
	e := newTestEnv(t)
	conn := testdb.Open(t)
	testdb.User(t, conn, 1_799_531, map[string]any{"username": "gowebwwwseller"})
	addCustomDomain(t, conn, 1_799_532, "www.example.com", map[string]any{"user_id": 1_799_531})
	addCustomDomain(t, conn, 1_799_533, "example.com", nil)
	if w := e.get("www.example.com", "/l/guide", customDomainHeaders(nil)); w.Code != http.StatusOK || e.railsHit != nil {
		t.Errorf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
}

// fetch_leniently is scoped to the domain's owner, so another seller's product is a 404.
func TestAnotherSellersProductOnACustomDomain(t *testing.T) {
	e := newTestEnv(t)
	conn := testdb.Open(t)
	testdb.User(t, conn, 1_799_521, map[string]any{"username": "gowebotherseller"})
	addCustomDomain(t, conn, 1_799_522, "shop.example.com", map[string]any{"user_id": 1_799_521})
	if w := e.get("shop.example.com", "/l/guide", customDomainHeaders(nil)); w.Code != http.StatusNotFound || e.railsHit != nil {
		t.Errorf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
}

// A product's own domain renders that product whatever the path names, never redirects, and
// links to its seller's subdomain: user_by_domain finds no seller there, and the canonical URL
// is the product's long URL. track_utm_link_visit records nothing on it.
func TestAProductsCustomDomain(t *testing.T) {
	const domain = "guide.example.com"
	e := newTestEnv(t)
	conn := testdb.Open(t)
	jobs := miniredis.RunT(t)
	e.config.Page.Sidekiq = &sidekiq.Client{Redis: redis.NewClient(&redis.Options{Addr: jobs.Addr()}), RedisVersion: "7.2.4"}
	addCustomDomain(t, conn, 1_799_541, domain, map[string]any{"user_id": nil, "product_id": productID})
	for _, path := range []string{"/l/anything", "/l/gowebp1?utm_source=a&utm_medium=b&utm_campaign=c&recommended_by=search"} {
		w := e.get(domain, path, customDomainHeaders(map[string]string{"Cookie": "_gumroad_guid=guid-1"}))
		if w.Code != http.StatusOK || e.railsHit != nil {
			t.Fatalf("%s: %d %q", path, w.Code, w.Header().Get("X-Go-Web-Fallback"))
		}
		body := w.Body.String()
		product := pageProps(t, body)["product"].(map[string]any)
		profileURL := "https://" + host
		if strings.Contains(path, "recommended_by") {
			profileURL += "?recommended_by=search"
		}
		if product["permalink"] != "gowebp1" || product["seller"].(map[string]any)["profile_url"] != profileURL {
			t.Errorf("%s: %v %v", path, product["permalink"], product["seller"])
		}
		if want := `<link rel="canonical" href="https://` + host + `/l/guide"`; !strings.Contains(body, want) {
			t.Errorf("%s: missing %s", path, want)
		}
	}
	if queued, _ := jobs.List("queue:default"); len(queued) != 0 {
		t.Errorf("queued %v", queued)
	}
}

// User#username falls back to the external id, so an owner without one still routes here, and
// the subdomain it names is the external id's.
func TestACustomDomainOwnerWithoutAUsername(t *testing.T) {
	e := newTestEnv(t)
	conn := testdb.Open(t)
	addCustomDomain(t, conn, 1_799_551, "shop.example.com", nil)
	mustExec(t, conn, "UPDATE users SET username = NULL WHERE id = ?", sellerID)
	w := e.get("shop.example.com", "/l/guide", customDomainHeaders(nil))
	if w.Code != http.StatusOK || e.railsHit != nil {
		t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
	if want := `"long_url":"https://1790001.gumroad.com/l/guide"`; !strings.Contains(html.UnescapeString(w.Body.String()), want) {
		t.Errorf("missing %s", want)
	}
}

// On a product's domain the code's path renders too, noindexed, and a banned product is a 404
// with no UTM visit to record first.
func TestAProductsCustomDomainShapes(t *testing.T) {
	const domain = "guide.example.com"
	e := newTestEnv(t)
	conn := testdb.Open(t)
	jobs := miniredis.RunT(t)
	e.config.Page.Sidekiq = &sidekiq.Client{Redis: redis.NewClient(&redis.Options{Addr: jobs.Addr()}), RedisVersion: "7.2.4"}
	addCustomDomain(t, conn, 1_799_561, domain, map[string]any{"user_id": nil, "product_id": productID})
	if w := e.get(domain, "/l/guide/save10", customDomainHeaders(nil)); w.Code != http.StatusOK || w.Header().Get("X-Robots-Tag") != "noindex" {
		t.Errorf("code path: %d %q %q", w.Code, w.Header().Get("X-Robots-Tag"), w.Header().Get("X-Go-Web-Fallback"))
	}
	mustExec(t, conn, "UPDATE links SET banned_at = ? WHERE id = ?", testNow, productID)
	if w := e.get(domain, "/l/guide?utm_source=a&utm_medium=b&utm_campaign=c", customDomainHeaders(nil)); w.Code != http.StatusNotFound || e.railsHit != nil {
		t.Errorf("banned: %d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
}

// A storefront card on a product's domain links to the seller's subdomain, as long_url does.
func TestAProductsCustomDomainStorefrontCard(t *testing.T) {
	const domain = "guide.example.com"
	e := newTestEnv(t)
	conn := testdb.Open(t)
	mustExec(t, conn, "UPDATE users SET flags = flags | ? WHERE id = ?", userProductPageStorefrontEnabled, sellerID)
	testdb.Insert(t, conn, "links", map[string]any{"id": ownOther, "user_id": sellerID, "name": "Other", "unique_permalink": "gowebown2",
		"price_cents": 300, "created_at": testNow, "updated_at": testNow})
	testdb.Insert(t, conn, "prices", map[string]any{"id": int64(1_799_002), "link_id": ownOther, "price_cents": 300, "currency": "usd",
		"created_at": testNow, "updated_at": testNow})
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, fmt.Sprintf(`{"hits":{"total":{"value":2,"relation":"eq"},"hits":[{"_id":"%d","sort":[1762430000000]},`+
			`{"_id":"%d","sort":[1762420000000]}]},"aggregations":{"tags.keyword":{"buckets":[]},"filetypes.keyword":{"buckets":[]}}}`,
			ownOther, productID))
	}))
	t.Cleanup(server.Close)
	client, err := elastic.NewWithClient(server.URL, server.Client())
	if err != nil {
		t.Fatal(err)
	}
	e.config.Page.Search = client
	addCustomDomain(t, conn, 1_799_571, domain, map[string]any{"user_id": nil, "product_id": productID})
	w := e.get(domain, "/l/guide?recommended_by=search", customDomainHeaders(nil))
	if w.Code != http.StatusOK || e.railsHit != nil {
		t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
	want := `"url":"https://` + host + `/l/gowebown2?layout=profile\u0026recommended_by=search"`
	if page := html.UnescapeString(dataPage.FindStringSubmatch(w.Body.String())[1]); !strings.Contains(page, want) {
		t.Errorf("missing %s", want)
	}
}
