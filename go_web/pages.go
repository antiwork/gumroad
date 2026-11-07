package main

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"log/slog"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
	"github.com/redis/go-redis/v9"

	"github.com/antiwork/gumroad/go_web/internal/delivery"
	"github.com/antiwork/gumroad/go_web/internal/downloads"
	"github.com/antiwork/gumroad/go_web/internal/elastic"
	"github.com/antiwork/gumroad/go_web/internal/flipper"
	"github.com/antiwork/gumroad/go_web/internal/inertia"
	"github.com/antiwork/gumroad/go_web/internal/obfuscate"
	"github.com/antiwork/gumroad/go_web/internal/pages"
	"github.com/antiwork/gumroad/go_web/internal/products"
	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/railscache"
	"github.com/antiwork/gumroad/go_web/internal/sidekiq"
	"github.com/antiwork/gumroad/go_web/internal/storage"
	"github.com/antiwork/gumroad/go_web/internal/vite"
	"github.com/antiwork/gumroad/go_web/internal/web"
)

// errPagesOff is a config that leaves full pages to Rails.
var errPagesOff = errors.New("full pages are off")

// pageConfig is what full pages need, or errPagesOff with the reason when something they
// read is missing. Only production's CDN_URL_MAP is ported.
func (d *dependencies) pageConfig(s3Client *s3.Client, ids *obfuscate.IDs) (*downloads.PageConfig, error) {
	env := d.env
	dir, cable := getenv("VITE_MANIFEST_DIR"), getenv("ANYCABLE_WEBSOCKET_URL")
	digestKey, dropboxKey := d.config("OBFUSCATE_IDS_CIPHER_KEY"), d.config("DROPBOX_PICKER_API_KEY")
	switch {
	case env.Name != "production":
		return nil, fmt.Errorf("%w: RAILS_ENV %s", errPagesOff, env.Name)
	case dir == "" || cable == "":
		return nil, fmt.Errorf("%w: VITE_MANIFEST_DIR or ANYCABLE_WEBSOCKET_URL is not set", errPagesOff)
	case digestKey == "" || dropboxKey == "":
		// Rails would render nil for these.
		return nil, fmt.Errorf("%w: OBFUSCATE_IDS_CIPHER_KEY or DROPBOX_PICKER_API_KEY is not set", errPagesOff)
	}
	manifest, err := vite.LoadDir(env.AssetHost(), dir)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", errPagesOff, err)
	}
	layout, err := inertia.NewLayout(inertia.LayoutConfig{
		OGNamespace:    d.config("FACEBOOK_OG_NAMESPACE"),
		DNSPrefetch:    []string{env.AssetHost(), env.S3ProxyHost, env.PublicStorageHost},
		ActionCableURL: cable,
		Manifest:       manifest,
	})
	if err != nil {
		return nil, fmt.Errorf("%w: %v", errPagesOff, err)
	}
	csp, err := web.NewCSP(env, d.globalConfig)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", errPagesOff, err)
	}
	conn, err := d.database()
	if err != nil {
		return nil, err
	}
	s3Endpoint := d.globalConfig("AWS_S3_ENDPOINT", "https://s3.amazonaws.com")
	return &downloads.PageConfig{
		Layout: layout,
		CSP:    csp,
		Shared: pages.NewShared(env, flipper.New(d.redis, "disable_stripe_signup").Active),
		Avatars: &storage.Avatars{
			DB:        conn,
			Exists:    s3Exister{client: s3Client, bucket: env.PublicStorageBucket},
			AssetHost: env.AssetHost(),
			// The public service's url, which avatar.url answers.
			PublicStorage: "https://" + env.PublicStorageBucket + ".s3.amazonaws.com/",
			// CDN_URL_MAP's https://<bucket>.s3.amazonaws.com/ => PUBLIC_STORAGE_CDN_S3_PROXY_HOST/.
			PublicCDN: env.PublicStorageHost + "/",
			Now:       time.Now,
			Logger:    d.logger,
		},
		Content: delivery.ContentConfig{
			IDs:       ids,
			S3BaseURL: d.globalConfig("S3_BASE_URL_TEMPLATE", s3Endpoint+"/gumroad/"),
			AssetHost: env.AssetHost(),
		},
		EmailDigestKey:  digestKey,
		DropboxAPIKey:   dropboxKey,
		IOSAppID:        d.globalConfig("IOS_APP_ID", "916819108"),
		AndroidBundleID: d.globalConfig("ANDROID_BUNDLE_ID", "com.gumroad.app"),
		NewNonce:        newNonce,
	}, nil
}

// globalConfig is GlobalConfig.get(name, default): a set variable wins even when empty,
// then a credential that is set, then the default.
func (d *dependencies) globalConfig(name, fallback string) string {
	if value, ok := lookupenv(name); ok {
		return value
	}
	if value, ok := d.credentials.Lookup(name); ok && value != "false" {
		return value
	}
	return fallback
}

// newNonce is SecureHeaders' SecureRandom.base64(32).
func newNonce() string {
	var b [32]byte
	rand.Read(b[:])
	return base64.StdEncoding.EncodeToString(b[:])
}

// s3ExistsTimeout bounds the presence check on the request path; a slow answer counts as
// present, as a failed one does in Rails.
const s3ExistsTimeout = time.Second

// s3Exister is S3Service#exist?: false only for a key S3 says isn't there.
type s3Exister struct {
	client *s3.Client
	bucket string
}

func (e s3Exister) Exists(ctx context.Context, key string) (bool, error) {
	ctx, cancel := context.WithTimeout(ctx, s3ExistsTimeout)
	defer cancel()
	_, err := e.client.HeadObject(ctx, &s3.HeadObjectInput{Bucket: aws.String(e.bucket), Key: aws.String(key)},
		func(o *s3.Options) { o.RetryMaxAttempts = 1 })
	var notFound *types.NotFound
	if errors.As(err, &notFound) {
		return false, nil
	}
	return err == nil, err
}

// memcacheTimeout is Dalli's socket timeout, which Rails.cache uses.
const memcacheTimeout = time.Second

// railsRevisionInterval is how often go_web asks the Rails hosts which REVISION they run.
const railsRevisionInterval = time.Minute

// followRailsRevision keeps cache on the REVISION the Rails hosts run. Rails namespaces
// Rails.cache, and its profile sections' keys, by its own deploy's REVISION, which moves on
// every deploy while go_web rolls only on its own changes. An unknown one keeps the last.
func followRailsRevision(proxy *web.RailsProxy, cache *railscache.Store, logger *slog.Logger, stop <-chan struct{}) {
	ticker := time.NewTicker(railsRevisionInterval)
	defer ticker.Stop()
	for {
		if r := proxy.Revision(context.Background()); r != "" && r != cache.Namespace() {
			logger.Info("following Rails' cache namespace", "revision", r)
			cache.SetNamespace(r)
		}
		select {
		case <-stop:
			return
		case <-ticker.C:
		}
	}
}

// productPageConfig is what the product page reads beyond the shared page config, or
// errPagesOff. Its Rails.cache reads and writes follow the Rails hosts' REVISION namespace (see
// followRailsRevision), starting from go_web's own.
func (d *dependencies) productPageConfig(b *pageBase) (*products.PageConfig, error) {
	if b.pages == nil {
		return nil, fmt.Errorf("%w: download page config", errPagesOff)
	}
	servers := getenv("MEMCACHE_SERVERS")
	if servers == "" || d.env.Revision == "" {
		return nil, fmt.Errorf("%w: MEMCACHE_SERVERS or REVISION is not set", errPagesOff)
	}
	cache, err := railscache.New(strings.Split(servers, ","), d.env.Revision, memcacheTimeout)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", errPagesOff, err)
	}
	d.closers = append(d.closers, func() error { cache.Close(); return nil })
	if b.proxy != nil {
		stop := make(chan struct{})
		go followRailsRevision(b.proxy, cache, d.logger, stop)
		d.closers = append(d.closers, func() error { close(stop); return nil })
	}
	geo, err := d.geoIP()
	if err != nil {
		return nil, err
	}
	env := d.env
	recaptcha := d.globalConfig("RECAPTCHA_FOLLOW_SITE_KEY", "")
	if rails.Blank(recaptcha) {
		recaptcha = d.globalConfig("RECAPTCHA_MONEY_SITE_KEY", "")
	}
	s3Endpoint := d.globalConfig("AWS_S3_ENDPOINT", "https://s3.amazonaws.com")
	flags := &flagSet{redis: d.redis, flags: map[string]*flipper.Flag{}}
	var search *elastic.Client
	if host := getenv("ELASTICSEARCH_HOST"); host != "" {
		// Only what needs a search goes to Rails without it.
		if search, err = elastic.New(host); err != nil {
			d.logger.Warn("product page searches left to Rails", "reason", err.Error())
		}
	}
	var jobs *sidekiq.Client
	if conn, err := d.sidekiqRedis(); err != nil {
		d.logger.Warn("product page jobs left to Rails", "reason", err.Error())
	} else {
		jobs = &sidekiq.Client{Redis: conn}
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		if err := jobs.LoadRedisVersion(ctx); err != nil {
			// The unique-jobs scripts take the version without reading it.
			d.logger.Warn("Sidekiq Redis version unread", "reason", err.Error())
		}
		cancel()
	}
	// GlobalConfig.get("GUMROAD_ADMIN_ID", 767082) in production.
	gumroadAdminID, _ := strconv.ParseInt(d.globalConfig("GUMROAD_ADMIN_ID", "767082"), 10, 64)
	var customHTML *vite.Tags
	manifest := b.pages.Layout.Manifest()
	if tags, err := manifest.TypescriptTag("custom_html_analytics"); err != nil {
		d.logger.Warn("custom HTML product pages left to Rails", "reason", err.Error())
	} else if _, err := manifest.EntrypointStylesheet("custom_html_analytics"); err == nil {
		// The wrapper's vite_typescript_tag renders style tags, which TypescriptTag leaves out.
		d.logger.Warn("custom HTML product pages left to Rails", "reason", "custom_html_analytics has stylesheets")
	} else {
		customHTML = &tags
	}
	calendar, err := manifest.AssetPath("components/ui/Calendar.tsx")
	if err != nil {
		d.logger.Warn("call product pages left to Rails", "reason", err.Error())
	}
	return &products.PageConfig{
		Layout:   b.pages.Layout,
		CSP:      b.pages.CSP,
		Shared:   b.pages.Shared,
		Avatars:  b.pages.Avatars,
		Cache:    cache,
		Revision: cache.Namespace,
		Redis:    d.redis,
		GeoIP:    geo,
		Flag:     flags.flag,
		// CDN_URL_MAP in production.
		CDNMap: [][2]string{
			{s3Endpoint + "/gumroad/", env.S3ProxyHost + "/res/gumroad/"},
			{"https://gumroad-public-storage.s3.amazonaws.com/", env.PublicStorageHost + "/"},
		},
		PublicStorageURL: b.pages.Avatars.PublicStorage,
		CalendarHref:     calendar,
		OGNamespace:      d.config("FACEBOOK_OG_NAMESPACE"),
		RecaptchaSiteKey: recaptcha,
		Search:           search,
		Sidekiq:          jobs,
		NewNonce:         newNonce,
		// Its tags are the same on every render.
		CustomHTMLAnalytics: customHTML,
		GumroadAdminID:      gumroadAdminID,
		EmailDigestKey:      b.pages.EmailDigestKey,
	}, nil
}

// flagSet keeps one Flipper flag reader per name.
type flagSet struct {
	redis *redis.Client
	mu    sync.Mutex
	flags map[string]*flipper.Flag
}

func (s *flagSet) flag(name string) *flipper.Flag {
	s.mu.Lock()
	defer s.mu.Unlock()
	f, ok := s.flags[name]
	if !ok {
		f = flipper.New(s.redis, name)
		s.flags[name] = f
	}
	return f
}
