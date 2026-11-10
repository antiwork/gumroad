// Command go_web serves Rails web routes that have been ported to Go. Each ported path
// reaches its fleet's nginx through its own ALB listener rule; everything else stays on Rails.
package main

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/redis/go-redis/v9"
	"github.com/redis/go-redis/v9/logging"

	"github.com/antiwork/gumroad/go_web/internal/credentials"
	"github.com/antiwork/gumroad/go_web/internal/errorreport"
	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/web"
)

const (
	defaultPort = "3000"

	// Inside the Nomad task's kill_timeout, with sentryFlushTimeout.
	shutdownTimeout    = 25 * time.Second
	sentryFlushTimeout = 2 * time.Second

	startupPingTimeout = 30 * time.Second
	pingRetryInterval  = time.Second

	redisTimeout  = 2 * time.Second
	redisPoolSize = 64

	readHeaderTimeout = 10 * time.Second
	requestTimeout    = 30 * time.Second
	idleTimeout       = 20 * time.Second
)

// lookupenv treats consul-template's "<no value>" as unset.
func lookupenv(name string) (string, bool) {
	if value, ok := os.LookupEnv(name); ok && value != "<no value>" {
		return value, true
	}
	return "", false
}

func getenv(name string) string {
	value, _ := lookupenv(name)
	return value
}

func main() {
	logging.Disable()
	logger := slog.New(errorreport.NewHandler(slog.NewJSONHandler(os.Stdout, nil)))
	if err := run(logger); err != nil {
		logger.Error(err.Error())
		errorreport.Flush(sentryFlushTimeout)
		os.Exit(1)
	}
}

func run(logger *slog.Logger) error {
	env, err := web.LoadEnvironment(getenv)
	if err != nil {
		return err
	}
	secrets, err := loadCredentials()
	if err != nil {
		return err
	}
	deps := &dependencies{env: env, logger: logger, credentials: secrets}
	// A bad DSN leaves reporting off, as sentry-ruby does, rather than the routes down.
	reporting, err := errorreport.Init(deps.config("SENTRY_DSN"), env.Name, env.Revision)
	if err != nil {
		logger.Warn("Sentry is off", "error", err.Error())
	}
	defer errorreport.Flush(sentryFlushTimeout)

	// $redis in Rails, not the Sidekiq Redis.
	redisClient, err := newRedis("REDIS_HOST")
	if err != nil {
		return err
	}
	defer redisClient.Close()

	app := web.NewApp(env, logger, redisClient)
	stack := rails.NewStack(env, getenv("CUSTOM_DOMAIN"))
	app.HandleNotFound(stack.NotFound())

	deps.redis, deps.stack = redisClient, stack
	defer deps.close()
	if err := registerRouteGroups(app, deps, getenv("GO_WEB_ROUTE_GROUPS")); err != nil {
		return err
	}

	port := getenv("PORT")
	if port == "" {
		port = defaultPort
	}
	httpServer := &http.Server{
		Addr:              ":" + port,
		Handler:           app,
		ReadHeaderTimeout: readHeaderTimeout,
		ReadTimeout:       requestTimeout,
		WriteTimeout:      requestTimeout,
		IdleTimeout:       idleTimeout,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	serveErr := make(chan error, 1)
	go func() { serveErr <- httpServer.ListenAndServe() }()
	logger.Info("listening", "port", port, "environment", env.Name, "sentry", reporting)

	select {
	case err := <-serveErr:
		return err
	case <-ctx.Done():
	}
	shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancel()
	return httpServer.Shutdown(shutdownCtx)
}

// loadCredentials opens RAILS_CREDENTIALS_PATH, the Rails credentials file baked into the image,
// with RAILS_MASTER_KEY. A path that is set must open.
func loadCredentials() (*credentials.Credentials, error) {
	path := getenv("RAILS_CREDENTIALS_PATH")
	if path == "" {
		return nil, nil
	}
	secrets, err := credentials.Load(path, getenv("RAILS_MASTER_KEY"))
	if err != nil {
		return nil, fmt.Errorf("RAILS_CREDENTIALS_PATH: %w", err)
	}
	return secrets, nil
}

// newRedis connects to the Redis named by hostVar and fails startup if it never answers,
// so a wrong host fails the deploy instead of every request.
func newRedis(hostVar string) (*redis.Client, error) {
	host := getenv(hostVar)
	if host == "" {
		return nil, fmt.Errorf("%s is not set", hostVar)
	}
	options, err := redis.ParseURL("redis://" + host)
	if err != nil {
		return nil, err
	}
	options.DialTimeout = redisTimeout
	options.ReadTimeout = redisTimeout
	options.WriteTimeout = redisTimeout
	options.PoolSize = redisPoolSize
	client := redis.NewClient(options)

	deadline := time.Now().Add(startupPingTimeout)
	for {
		ctx, cancel := context.WithTimeout(context.Background(), redisTimeout)
		err := client.Ping(ctx).Err()
		cancel()
		if err == nil {
			return client, nil
		}
		if time.Now().After(deadline) {
			client.Close()
			return nil, fmt.Errorf("%s is unreachable: %w", hostVar, err)
		}
		time.Sleep(pingRetryInterval)
	}
}
