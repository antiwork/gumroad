package robots

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"

	"github.com/antiwork/gumroad/go_web/internal/web"
)

const (
	gumroadBody    = "User-agent: *\nDisallow: /purchases/\n\nSitemap: https://public-files.gumroad.com/sitemap/products/1.xml\n"
	storefrontBody = "User-agent: bingbot\nCrawl-delay: 10\nDisallow: /purchases/\n\nUser-agent: *\nDisallow: /purchases/\n\n"
)

type fakeLister struct {
	keys  []string
	err   error
	calls int
}

func (l *fakeLister) ListKeys(_ context.Context, bucket, prefix string) ([]string, error) {
	l.calls++
	if bucket != "gumroad-public-storage" || prefix != "sitemap/" {
		return nil, errors.New("unexpected bucket or prefix")
	}
	return l.keys, l.err
}

func newHandler(t *testing.T, lister *fakeLister) (*Handler, *miniredis.Miniredis) {
	t.Helper()
	server := miniredis.RunT(t)
	client := redis.NewClient(&redis.Options{Addr: server.Addr()})
	t.Cleanup(func() { client.Close() })
	env, err := web.LoadEnvironment(func(name string) string {
		return map[string]string{"RAILS_ENV": "production", "REVISION": "r"}[name]
	})
	if err != nil {
		t.Fatal(err)
	}
	return NewHandler(env, client, lister), server
}

func get(h http.Handler, host string) *httptest.ResponseRecorder {
	r := httptest.NewRequest("GET", "/robots.txt", nil)
	r.Host = host
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}

func TestServesTheWildcardGroupAndCachedSitemapsOnTheGumroadHost(t *testing.T) {
	lister := &fakeLister{}
	h, server := newHandler(t, lister)
	server.Set(sitemapsKey, `["Sitemap: https://public-files.gumroad.com/sitemap/products/1.xml"]`)

	w := get(h, "gumroad.com")
	if w.Code != http.StatusOK || w.Body.String() != gumroadBody {
		t.Fatalf("got %d %q", w.Code, w.Body.String())
	}
	if lister.calls != 0 {
		t.Fatal("listed S3 although the sitemaps were cached")
	}
	if got := w.Header().Get("Content-Type"); got != "text/plain; charset=utf-8" {
		t.Fatalf("Content-Type = %q", got)
	}
	if got := w.Header().Get("Cache-Control"); got != "max-age=3600, public, stale-while-revalidate=86400" {
		t.Fatalf("Cache-Control = %q", got)
	}
	if w.Header().Get("Set-Cookie") != "" {
		t.Fatal("robots.txt must not set cookies, or Cloudflare will not share it")
	}
}

func TestAsksBingbotToSlowDownOnStorefrontHostsWithoutSitemaps(t *testing.T) {
	h, server := newHandler(t, &fakeLister{})
	server.Set(sitemapsKey, `["Sitemap: https://public-files.gumroad.com/sitemap/products/1.xml"]`)

	for _, host := range []string{"seller.gumroad.com", "example.com", "api.gumroad.com"} {
		if w := get(h, host); w.Code != http.StatusOK || w.Body.String() != storefrontBody {
			t.Errorf("%s: got %d %q", host, w.Code, w.Body.String())
		}
	}
}

func TestRefillsAMissingSitemapCacheFromS3WithAWeekTTL(t *testing.T) {
	lister := &fakeLister{keys: []string{"sitemap/products/1.xml", "sitemap/products/2.xml"}}
	h, server := newHandler(t, lister)

	w := get(h, "gumroad.com")
	want := "User-agent: *\nDisallow: /purchases/\n\n" +
		"Sitemap: https://public-files.gumroad.com/sitemap/products/1.xml\n" +
		"Sitemap: https://public-files.gumroad.com/sitemap/products/2.xml\n"
	if w.Body.String() != want {
		t.Fatalf("body = %q", w.Body.String())
	}
	cached, _ := server.Get(sitemapsKey)
	if cached != `["Sitemap: https://public-files.gumroad.com/sitemap/products/1.xml","Sitemap: https://public-files.gumroad.com/sitemap/products/2.xml"]` {
		t.Fatalf("cached %q", cached)
	}
	if ttl := server.TTL(sitemapsKey); ttl != 7*24*time.Hour {
		t.Fatalf("TTL = %v", ttl)
	}

	get(h, "gumroad.com")
	if lister.calls != 1 {
		t.Fatalf("listed S3 %d times", lister.calls)
	}
}

func TestCachesAnEmptySitemapListLikeRails(t *testing.T) {
	lister := &fakeLister{}
	h, server := newHandler(t, lister)

	if w := get(h, "gumroad.com"); w.Body.String() != "User-agent: *\nDisallow: /purchases/\n\n" {
		t.Fatalf("body = %q", w.Body.String())
	}
	if cached, _ := server.Get(sitemapsKey); cached != "[]" {
		t.Fatalf("cached %q", cached)
	}
}

func TestFailsTheGumroadHostWhenSitemapsCannotLoad(t *testing.T) {
	h, server := newHandler(t, &fakeLister{err: errors.New("s3 down")})
	if w := get(h, "gumroad.com"); w.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d", w.Code)
	}
	// Storefront hosts never read the sitemaps, so they keep serving.
	server.Close()
	if w := get(h, "seller.gumroad.com"); w.Code != http.StatusOK {
		t.Fatalf("storefront status = %d", w.Code)
	}
}

func TestRerendersWhenRailsReplacesTheSitemapList(t *testing.T) {
	h, server := newHandler(t, &fakeLister{})
	server.Set(sitemapsKey, `["Sitemap: https://public-files.gumroad.com/sitemap/products/1.xml"]`)
	first := get(h, "gumroad.com")
	server.Set(sitemapsKey, `["Sitemap: https://public-files.gumroad.com/sitemap/products/2.xml"]`)
	second := get(h, "gumroad.com")
	if !strings.Contains(second.Body.String(), "products/2.xml") || first.Header().Get("ETag") == second.Header().Get("ETag") {
		t.Fatalf("stale body %q", second.Body.String())
	}
}

func TestEscapesSitemapEntriesLikeTheTemplate(t *testing.T) {
	if got := render([]string{"User-agent: *"}, []string{"Sitemap: https://x/a?b=1&c=2"}); got != "User-agent: *\n\nSitemap: https://x/a?b=1&amp;c=2\n" {
		t.Fatalf("got %q", got)
	}
}
