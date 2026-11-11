package main

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log/slog"
	"slices"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/redis/go-redis/v9"

	"github.com/antiwork/gumroad/go_web/internal/beacons"
	"github.com/antiwork/gumroad/go_web/internal/credentials"
	"github.com/antiwork/gumroad/go_web/internal/db"
	"github.com/antiwork/gumroad/go_web/internal/downloads"
	"github.com/antiwork/gumroad/go_web/internal/geoip"
	"github.com/antiwork/gumroad/go_web/internal/inertia"
	"github.com/antiwork/gumroad/go_web/internal/licenses"
	"github.com/antiwork/gumroad/go_web/internal/obfuscate"
	"github.com/antiwork/gumroad/go_web/internal/pages"
	"github.com/antiwork/gumroad/go_web/internal/products"
	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/robots"
	"github.com/antiwork/gumroad/go_web/internal/session"
	"github.com/antiwork/gumroad/go_web/internal/sidekiq"
	"github.com/antiwork/gumroad/go_web/internal/web"
	"github.com/antiwork/gumroad/go_web/internal/webhooks"
)

// routeGroups are the GO_WEB_ROUTE_GROUPS names. A group stays off until its fleet has the
// config it needs, so merging a new group can't crash-loop a running fleet; an enabled group
// with missing config fails startup instead.
var routeGroups = map[string]func(*web.App, *dependencies) error{
	"robots":    registerRobots,
	"beacons":   registerBeacons,
	"licenses":  registerLicenses,
	"webhooks":  registerWebhooks,
	"downloads": registerDownloads,
	"products":  registerProducts,
}

const (
	defaultRouteGroups = "robots"
	dbPingTimeout      = 10 * time.Second
)

func registerRouteGroups(app *web.App, deps *dependencies, list string) error {
	if strings.TrimSpace(list) == "" {
		list = defaultRouteGroups
	}
	// Every name is checked before any group connects to anything, so a typo fails at once.
	var names []string
	for name := range strings.SplitSeq(list, ",") {
		name = strings.TrimSpace(name)
		if _, ok := routeGroups[name]; !ok {
			return fmt.Errorf("unknown route group %q in GO_WEB_ROUTE_GROUPS", name)
		}
		// A repeat would register the same patterns twice, which panics in the mux.
		if slices.Contains(names, name) {
			return fmt.Errorf("route group %q is listed twice in GO_WEB_ROUTE_GROUPS", name)
		}
		names = append(names, name)
	}
	for _, name := range names {
		if err := routeGroups[name](app, deps); err != nil {
			return fmt.Errorf("route group %s: %w", name, err)
		}
		deps.logger.Info("route group enabled", "group", name)
	}
	return nil
}

func registerRobots(app *web.App, d *dependencies) error {
	awsCfg, err := d.awsConfig()
	if err != nil {
		return err
	}
	// S3 is only read on a sitemap cache miss, so bad credentials would otherwise surface days later.
	if _, err := awsCfg.Credentials.Retrieve(context.Background()); err != nil {
		return fmt.Errorf("AWS credentials: %w", err)
	}
	app.Handle("GET /robots.txt", "RobotsController#index",
		robots.NewHandler(d.env, d.redis, &robots.S3Lister{Client: s3.NewFromConfig(awsCfg)}))
	return nil
}

func registerBeacons(app *web.App, d *dependencies) error {
	jobs, err := d.sidekiqRedis()
	if err != nil {
		return err
	}
	conn, err := d.database()
	if err != nil {
		return err
	}
	ids, err := d.obfuscatedIDs()
	if err != nil {
		return err
	}
	geo, err := d.geoIP()
	if err != nil {
		return err
	}
	return beacons.Register(app, beacons.Deps{
		Env:              d.env,
		Stack:            d.stack,
		DB:               conn,
		Redis:            d.redis,
		Sidekiq:          &sidekiq.Client{Redis: jobs},
		GeoIP:            geo,
		IDs:              ids,
		SecretKeyBase:    d.config("SECRET_KEY_BASE"),
		MobileToken:      d.config("MOBILE_TOKEN"),
		CustomDomain:     getenv("CUSTOM_DOMAIN"),
		BranchDeployment: branchDeployment(),
	})
}

func registerLicenses(app *web.App, d *dependencies) error {
	jobs, err := d.sidekiqRedis()
	if err != nil {
		return err
	}
	conn, err := d.database()
	if err != nil {
		return err
	}
	ids, err := d.obfuscatedIDs()
	if err != nil {
		return err
	}
	// A request with a session cookie goes to Rails, whose session filters aren't ported.
	proxy := d.railsProxy()
	if proxy == nil {
		return fmt.Errorf("RAILS_UPSTREAMS_FILE is not set")
	}
	licenses.Register(app, licenses.Deps{Env: d.env, Stack: d.stack, DB: conn, Redis: d.redis, SidekiqRedis: jobs, IDs: ids,
		Proxy: proxy, SessionCookie: d.sessionCookieName()})
	return nil
}

// stripeAPIVersion is config/initializers/003_stripe.rb's Stripe.api_version outside test.
const stripeAPIVersion = "2023-10-16; risk_in_requirements_beta=v1; retrieve_tax_forms_beta=v1;"

// pageBase is what every page group shares: the request lifecycle's pieces and the full
// pages' layout, which is nil (with errPagesOff logged) when their config is missing.
type pageBase struct {
	conn     *sql.DB
	ids      *obfuscate.IDs
	store    *session.Store
	resolver *session.Resolver
	proxy    *web.RailsProxy
	meta     inertia.DefaultMeta
	pages    *downloads.PageConfig
}

func (d *dependencies) pageBase() (*pageBase, error) {
	if d.pages != nil {
		return d.pages, nil
	}
	proxy := d.railsProxy()
	if proxy == nil {
		return nil, fmt.Errorf("RAILS_UPSTREAMS_FILE is not set")
	}
	conn, err := d.database()
	if err != nil {
		return nil, err
	}
	ids, err := d.obfuscatedIDs()
	if err != nil {
		return nil, err
	}
	codec, err := session.NewCodec(d.config("SECRET_KEY_BASE"))
	if err != nil {
		return nil, err
	}
	// 003_stripe.rb's GlobalConfig.get with its default.
	stripePublicKey := d.globalConfig("STRIPE_PUBLIC_KEY_PROD", "pk_live_Db80xIzLPWhKo1byPrnERmym")
	if d.env.Name != "production" {
		stripePublicKey = d.globalConfig("STRIPE_PUBLIC_KEY_TEST", "pk_test_ehGPKw3JPRHYiqEEjgJ02ULC")
	}
	awsCfg, err := d.awsConfig()
	if err != nil {
		return nil, err
	}
	pageConfig, err := d.pageConfig(s3.NewFromConfig(awsCfg), ids)
	if errors.Is(err, errPagesOff) {
		d.logger.Info("full pages left to Rails", "reason", err.Error())
	} else if err != nil {
		return nil, err
	}
	d.pages = &pageBase{
		conn:     conn,
		ids:      ids,
		store:    session.NewStore(codec, d.env.Name, d.env.Protocol, getenv("CUSTOM_DOMAIN"), branchDeployment()),
		resolver: &session.Resolver{Users: &session.Users{DB: conn}, Redis: d.redis, Codec: codec},
		proxy:    proxy,
		meta: inertia.DefaultMeta{
			Title:                  d.env.PageTitle,
			Environment:            d.env.Name,
			FacebookAppID:          d.config("FACEBOOK_APP_ID"),
			StripePublicKey:        stripePublicKey,
			StripeAPIVersion:       stripeAPIVersion,
			AssetHost:              d.env.AssetHost(),
			AnalyticsByEnvironment: d.env.Name == "production" || d.env.Name == "staging",
		},
		pages: pageConfig,
	}
	return d.pages, nil
}

// registerDownloads serves the download page and its polls and hands the rest to Rails.
func registerDownloads(app *web.App, d *dependencies) error {
	b, err := d.pageBase()
	if err != nil {
		return err
	}
	downloads.Register(app, &downloads.Config{
		Env: d.env, DB: b.conn, Stack: d.stack, Store: b.store, Resolver: b.resolver, IDs: b.ids, Proxy: b.proxy, Meta: b.meta,
		Now: time.Now, Pages: b.pages, DryRunKey: pages.DryRunKey(d.config("SECRET_KEY_BASE")), DryRunOnce: d.redis,
	})
	return nil
}

// registerProducts serves the product page and hands the rest to Rails.
func registerProducts(app *web.App, d *dependencies) error {
	b, err := d.pageBase()
	if err != nil {
		return err
	}
	page, err := d.productPageConfig(b)
	if errors.Is(err, errPagesOff) {
		d.logger.Info("product pages left to Rails", "reason", err.Error())
	} else if err != nil {
		return err
	}
	products.Register(app, &products.Config{
		Env: d.env, DB: b.conn, Stack: d.stack, Store: b.store, Resolver: b.resolver, IDs: b.ids, Proxy: b.proxy, Meta: b.meta,
		Now: time.Now, Page: page, DryRunKey: pages.DryRunKey(d.config("SECRET_KEY_BASE")), DryRunOnce: d.redis,
	})
	return nil
}

// registerWebhooks turns each route on only when its secret is set, so the group can be enabled
// before every provider's secret is in Vault.
func registerWebhooks(app *web.App, d *dependencies) error {
	jobs, err := d.sidekiqRedis()
	if err != nil {
		return err
	}
	return webhooks.Register(app, webhooks.Deps{
		Env:                         d.env,
		Stack:                       d.stack,
		Redis:                       d.redis,
		Sidekiq:                     &sidekiq.Client{Redis: jobs},
		StripeEndpointSecret:        d.config("STRIPE__ENDPOINT_SECRET"),
		StripeConnectEndpointSecret: d.config("STRIPE_CONNECT__ENDPOINT_SECRET"),
		PaypalWebhookID:             d.config("PAYPAL_WEBHOOK_ID"),
		PaypalPartnerClientID:       d.config("PAYPAL_PARTNER_CLIENT_ID"),
		PaypalPartnerClientSecret:   d.config("PAYPAL_PARTNER_CLIENT_SECRET"),
		SendgridPublicKeys:          webhooks.SendgridPublicKeys(d.config),
		Logger:                      d.logger,
	})
}

// dependencies opens each shared connection the first time an enabled group needs it.
type dependencies struct {
	env    *web.Environment
	logger *slog.Logger
	redis  *redis.Client
	stack  *rails.Stack

	credentials *credentials.Credentials
	aws         *aws.Config

	jobs    *redis.Client
	conn    *sql.DB
	ids     *obfuscate.IDs
	proxy   *web.RailsProxy
	geo     *geoip.Reader
	geoRead bool
	pages   *pageBase
	closers []func() error
}

// geoIP is the GEOIP Rails loads: nil when the mmdb is missing, and a path that is set
// must open.
func (d *dependencies) geoIP() (*geoip.Reader, error) {
	if d.geoRead {
		return d.geo, nil
	}
	if path := getenv("GEOIP_DATABASE_PATH"); path != "" {
		geo, err := geoip.Open(path)
		if err != nil {
			return nil, fmt.Errorf("GEOIP_DATABASE_PATH: %w", err)
		}
		d.closers = append(d.closers, geo.Close)
		d.geo = geo
	}
	d.geoRead = true
	return d.geo, nil
}

// sessionCookieName is session_store.rb's key.
func (d *dependencies) sessionCookieName() string {
	return session.CookieName(d.env.Name, getenv("CUSTOM_DOMAIN"), branchDeployment())
}

func branchDeployment() bool { return getenv("BRANCH_DEPLOYMENT") != "" }

// railsProxy hands requests to Rails, from RAILS_UPSTREAMS_FILE's list; nil without one.
func (d *dependencies) railsProxy() *web.RailsProxy {
	if d.proxy == nil {
		if upstreams := getenv("RAILS_UPSTREAMS_FILE"); upstreams != "" {
			d.proxy = web.NewRailsProxy(upstreams)
		}
	}
	return d.proxy
}

// config reads a secret as Rails does, through GlobalConfig.get or secret_key_base: a set
// variable wins, then the credentials file, and a blank value is nil.
func (d *dependencies) config(name string) string {
	value, ok := lookupenv(name)
	if !ok {
		value, _ = d.credentials.Lookup(name)
	}
	if rails.Blank(value) {
		return ""
	}
	return value
}

// awsConfig is the AWS SDK's default config, loaded once.
func (d *dependencies) awsConfig() (aws.Config, error) {
	if d.aws == nil {
		cfg, err := awsconfig.LoadDefaultConfig(context.Background(), awsconfig.WithDefaultRegion("us-east-1"))
		if err != nil {
			return aws.Config{}, err
		}
		d.aws = &cfg
	}
	return *d.aws, nil
}

// sidekiqRedis is SIDEKIQ_REDIS_HOST, separate from $redis.
func (d *dependencies) sidekiqRedis() (*redis.Client, error) {
	if d.jobs == nil {
		client, err := newRedis("SIDEKIQ_REDIS_HOST")
		if err != nil {
			return nil, err
		}
		d.jobs = client
		d.closers = append(d.closers, client.Close)
	}
	return d.jobs, nil
}

func (d *dependencies) database() (*sql.DB, error) {
	if d.conn == nil {
		conn, err := db.Open(getenv)
		if err != nil {
			return nil, err
		}
		ctx, cancel := context.WithTimeout(context.Background(), dbPingTimeout)
		defer cancel()
		if err := conn.PingContext(ctx); err != nil {
			conn.Close()
			return nil, fmt.Errorf("MySQL is unreachable: %w", err)
		}
		d.conn = conn
		d.closers = append(d.closers, conn.Close)
	}
	return d.conn, nil
}

func (d *dependencies) obfuscatedIDs() (*obfuscate.IDs, error) {
	if d.ids == nil {
		ids, err := obfuscate.New(d.config("OBFUSCATE_IDS_CIPHER_KEY"), d.config("OBFUSCATE_IDS_NUMERIC_CIPHER_KEY"))
		if err != nil {
			return nil, err
		}
		d.ids = ids
	}
	return d.ids, nil
}

func (d *dependencies) close() {
	for i := len(d.closers) - 1; i >= 0; i-- {
		d.closers[i]()
	}
}
