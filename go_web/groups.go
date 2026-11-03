package main

import (
	"context"
	"database/sql"
	"fmt"
	"log/slog"
	"strings"
	"time"

	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/redis/go-redis/v9"

	"github.com/antiwork/gumroad/go_web/internal/beacons"
	"github.com/antiwork/gumroad/go_web/internal/db"
	"github.com/antiwork/gumroad/go_web/internal/geoip"
	"github.com/antiwork/gumroad/go_web/internal/licenses"
	"github.com/antiwork/gumroad/go_web/internal/obfuscate"
	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/robots"
	"github.com/antiwork/gumroad/go_web/internal/sidekiq"
	"github.com/antiwork/gumroad/go_web/internal/web"
	"github.com/antiwork/gumroad/go_web/internal/webhooks"
)

// routeGroups are the GO_WEB_ROUTE_GROUPS names. A group stays off until its fleet has the
// config it needs, so merging a new group can't crash-loop a running fleet; an enabled group
// with missing config fails startup instead.
var routeGroups = map[string]func(*web.App, *dependencies) error{
	"robots":   registerRobots,
	"beacons":  registerBeacons,
	"licenses": registerLicenses,
	"webhooks": registerWebhooks,
}

const (
	defaultRouteGroups = "robots"
	dbPingTimeout      = 10 * time.Second
)

func registerRouteGroups(app *web.App, deps *dependencies, list string) error {
	if strings.TrimSpace(list) == "" {
		list = defaultRouteGroups
	}
	for name := range strings.SplitSeq(list, ",") {
		name = strings.TrimSpace(name)
		register, ok := routeGroups[name]
		if !ok {
			return fmt.Errorf("unknown route group %q in GO_WEB_ROUTE_GROUPS", name)
		}
		if err := register(app, deps); err != nil {
			return fmt.Errorf("route group %s: %w", name, err)
		}
		deps.logger.Info("route group enabled", "group", name)
	}
	return nil
}

func registerRobots(app *web.App, d *dependencies) error {
	awsCfg, err := awsconfig.LoadDefaultConfig(context.Background(), awsconfig.WithDefaultRegion("us-east-1"))
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
	// GEOIP is nil in Rails when the mmdb is missing; a path that is set must open.
	var geo *geoip.Reader
	if path := getenv("GEOIP_DATABASE_PATH"); path != "" {
		if geo, err = geoip.Open(path); err != nil {
			return fmt.Errorf("GEOIP_DATABASE_PATH: %w", err)
		}
		d.closers = append(d.closers, geo.Close)
	}
	return beacons.Register(app, beacons.Deps{
		Env:              d.env,
		Stack:            d.stack,
		DB:               conn,
		Redis:            d.redis,
		Sidekiq:          &sidekiq.Client{Redis: jobs},
		GeoIP:            geo,
		IDs:              ids,
		SecretKeyBase:    getenv("SECRET_KEY_BASE"),
		MobileToken:      getenv("MOBILE_TOKEN"),
		CustomDomain:     getenv("CUSTOM_DOMAIN"),
		BranchDeployment: getenv("BRANCH_DEPLOYMENT") != "",
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
	licenses.Register(app, licenses.Deps{Env: d.env, Stack: d.stack, DB: conn, Redis: d.redis, SidekiqRedis: jobs, IDs: ids})
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
		StripeEndpointSecret:        getenv("STRIPE__ENDPOINT_SECRET"),
		StripeConnectEndpointSecret: getenv("STRIPE_CONNECT__ENDPOINT_SECRET"),
		SendgridPublicKeys:          webhooks.SendgridPublicKeys(getenv),
		Logger:                      d.logger,
	})
}

// dependencies opens each shared connection the first time an enabled group needs it.
type dependencies struct {
	env    *web.Environment
	logger *slog.Logger
	redis  *redis.Client
	stack  *rails.Stack

	jobs    *redis.Client
	conn    *sql.DB
	ids     *obfuscate.IDs
	closers []func() error
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
		ids, err := obfuscate.New(getenv("OBFUSCATE_IDS_CIPHER_KEY"), getenv("OBFUSCATE_IDS_NUMERIC_CIPHER_KEY"))
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
