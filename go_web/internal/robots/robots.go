// Package robots replaces RobotsController#index and RobotsService.
package robots

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/redis/go-redis/v9"
	"golang.org/x/sync/singleflight"

	"github.com/antiwork/gumroad/go_web/internal/web"
)

const (
	// RobotsService's Redis::Namespace key, shared with Rails, which also refills it.
	sitemapsKey    = "robots_redis_namespace:sitemap_configs"
	sitemapsTTL    = 7 * 24 * time.Hour
	sitemapsPrefix = "sitemap/"
	refillTimeout  = 20 * time.Second

	bingbotCrawlDelaySeconds = 10
	// RobotsController::CACHE_TTL and STALE_WHILE_REVALIDATE.
	cacheControl = "max-age=3600, public, stale-while-revalidate=86400"
)

var disallowRules = []string{"Disallow: /purchases/"}

// Lister lists the keys under a bucket prefix in key order.
type Lister interface {
	ListKeys(ctx context.Context, bucket, prefix string) ([]string, error)
}

type Handler struct {
	env        *web.Environment
	redis      redis.Cmdable
	lister     Lister
	refill     singleflight.Group
	gumroad    atomic.Pointer[rendered]
	storefront rendered
}

type rendered struct {
	source, body, etag string
}

func NewHandler(env *web.Environment, redisClient redis.Cmdable, lister Lister) *Handler {
	body := render(userAgentRules(true), nil)
	return &Handler{
		env:        env,
		redis:      redisClient,
		lister:     lister,
		storefront: rendered{body: body, etag: web.ETag(body)},
	}
}

func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	page := &h.storefront
	if h.env.IsGumroadHost(web.Host(r)) {
		var err error
		if page, err = h.gumroadPage(r.Context()); err != nil {
			if web.ClientLeft(w, r, err) {
				return
			}
			web.Logger(r).Error("Could not load sitemap configs", "error", err.Error())
			web.InternalServerError(w)
			return
		}
	}
	w.Header().Set("Cache-Control", cacheControl)
	web.WriteCacheable(w, r, web.TextPlain, page.etag, page.body)
}

func userAgentRules(storefront bool) []string {
	var rules []string
	if storefront {
		rules = append(rules, "User-agent: bingbot", "Crawl-delay: "+strconv.Itoa(bingbotCrawlDelaySeconds))
		rules = append(rules, disallowRules...)
		rules = append(rules, "")
	}
	rules = append(rules, "User-agent: *")
	return append(rules, disallowRules...)
}

// render produces app/views/robots/index.erb's exact bytes under Erubi's trim mode.
func render(rules, sitemaps []string) string {
	var b strings.Builder
	writeLines(&b, rules)
	b.WriteByte('\n')
	writeLines(&b, sitemaps)
	return b.String()
}

func writeLines(b *strings.Builder, lines []string) {
	for _, line := range lines {
		b.WriteString(web.HTMLEscape(line))
		b.WriteByte('\n')
	}
}

// gumroadPage reads the sitemap list on every request, as Rails does, but only re-renders
// when it changed.
func (h *Handler) gumroadPage(ctx context.Context) (*rendered, error) {
	data, err := h.redis.Get(ctx, sitemapsKey).Result()
	if errors.Is(err, redis.Nil) || (err == nil && strings.TrimSpace(data) == "") {
		data, err = h.refillSitemaps(ctx)
	}
	if err != nil {
		return nil, err
	}
	if page := h.gumroad.Load(); page != nil && page.source == data {
		return page, nil
	}
	var sitemaps []string
	if err := json.Unmarshal([]byte(data), &sitemaps); err != nil {
		return nil, err
	}
	body := render(userAgentRules(false), sitemaps)
	page := &rendered{source: data, body: body, etag: web.ETag(body)}
	h.gumroad.Store(page)
	return page, nil
}

// refillSitemaps lists S3 once per miss, however many requests are waiting, and detaches the
// listing from any one request so a client hanging up can't cancel it for the rest.
func (h *Handler) refillSitemaps(ctx context.Context) (string, error) {
	result := h.refill.DoChan(sitemapsKey, func() (any, error) {
		ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), refillTimeout)
		defer cancel()
		keys, err := h.lister.ListKeys(ctx, h.env.PublicStorageBucket, sitemapsPrefix)
		if err != nil {
			return "", err
		}
		sitemaps := make([]string, len(keys))
		for i, key := range keys {
			sitemaps[i] = "Sitemap: " + h.env.PublicStorageHost + "/" + key
		}
		data, err := json.Marshal(sitemaps)
		if err != nil {
			return "", err
		}
		return string(data), h.redis.Set(ctx, sitemapsKey, data, sitemapsTTL).Err()
	})
	select {
	case <-ctx.Done():
		return "", ctx.Err()
	case res := <-result:
		if res.Err != nil {
			return "", res.Err
		}
		return res.Val.(string), nil
	}
}

// S3Lister lists with the SDK's paginator, which keeps Ruby's list_objects key order.
type S3Lister struct {
	Client *s3.Client
}

func (l *S3Lister) ListKeys(ctx context.Context, bucket, prefix string) ([]string, error) {
	var keys []string
	pages := s3.NewListObjectsV2Paginator(l.Client, &s3.ListObjectsV2Input{
		Bucket: aws.String(bucket),
		Prefix: aws.String(prefix),
	})
	for pages.HasMorePages() {
		page, err := pages.NextPage(ctx)
		if err != nil {
			return nil, err
		}
		for _, object := range page.Contents {
			keys = append(keys, aws.ToString(object.Key))
		}
	}
	return keys, nil
}
