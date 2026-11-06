package products

import (
	"database/sql"
	"maps"
	"net/http"
	"strings"
	"testing"

	"github.com/antiwork/gumroad/go_web/internal/session/testdb"
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
		{name: "a product's domain", reason: "product custom domain", setup: func(t *testing.T, conn *sql.DB) {
			addCustomDomain(t, conn, 1_799_511, shop, map[string]any{"user_id": nil, "product_id": productID})
		}},
		{name: "two rows for the domain", reason: "several custom domains for the host", setup: func(t *testing.T, conn *sql.DB) {
			addCustomDomain(t, conn, 1_799_511, shop, nil)
			addCustomDomain(t, conn, 1_799_512, "SHOP.example.com", nil)
		}},
		{name: "an owner without a username", reason: "no custom domain owner", setup: func(t *testing.T, conn *sql.DB) {
			addCustomDomain(t, conn, 1_799_511, shop, nil)
			mustExec(t, conn, "UPDATE users SET username = NULL WHERE id = ?", sellerID)
		}},
		{name: "a deleted owner", reason: "deleted custom domain owner", setup: func(t *testing.T, conn *sql.DB) {
			addCustomDomain(t, conn, 1_799_511, shop, nil)
			mustExec(t, conn, "UPDATE users SET deleted_at = ? WHERE id = ?", testNow, sellerID)
		}},
		// A newer suffix list than the gem's could split the host differently.
		{name: "a private suffix", host: "shop.goweb.github.io", reason: "custom domain suffix"},
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
