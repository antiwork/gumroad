// Command resend_callbacks receives webhooks on the callback fleet and enqueues their
// jobs exactly as ForeignWebhooksController does, without Rails.
package main

import (
	"context"
	"crypto/x509"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/redis/go-redis/v9"
	"github.com/redis/go-redis/v9/logging"
)

const (
	defaultPort    = "3000"
	countsInterval = time.Minute

	// Inside the Nomad task's 30s kill_timeout.
	shutdownTimeout = 25 * time.Second

	startupPingTimeout = 30 * time.Second
	pingRetryInterval  = time.Second

	// Per Redis call: each startup ping and each enqueue's SADD + LPUSH. A slow Redis
	// fails the request, so Resend retries it.
	redisTimeout  = 2 * time.Second
	redisPoolSize = 64
	// The flag is read only when a SendGrid signature check fails, at most every flagCacheTTL.
	flagPoolSize = 4

	readHeaderTimeout = 10 * time.Second
	requestTimeout    = 30 * time.Second
	// nginx expires its upstream keepalive sockets at 15s, so it never sends on one
	// this server is closing.
	idleTimeout = 20 * time.Second
)

func newRedisClient(host string, poolSize int, timeout time.Duration) (*redis.Client, error) {
	options, err := redis.ParseURL("redis://" + host)
	if err != nil {
		return nil, err
	}
	options.DialTimeout = timeout
	options.ReadTimeout = timeout
	options.WriteTimeout = timeout
	options.PoolSize = poolSize
	return redis.NewClient(options), nil
}

func pingRedis(client *redis.Client, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for {
		ctx, cancel := context.WithTimeout(context.Background(), redisTimeout)
		err := client.Ping(ctx).Err()
		cancel()
		if err == nil {
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("Sidekiq Redis is unreachable: %w", err)
		}
		time.Sleep(pingRetryInterval)
	}
}

// getenv treats consul-template's "<no value>", which a key missing from its Vault
// path renders as, as unset.
func getenv(name string) string {
	if value := os.Getenv(name); value != "<no value>" {
		return value
	}
	return ""
}

func main() {
	// go-redis otherwise prints every failed dial in its own format; enqueue failures
	// are already logged, rate-limited, by the handler.
	logging.Disable()
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	if err := run(logger); err != nil {
		logger.Error(err.Error())
		os.Exit(1)
	}
}

// configureOptionalRoutes turns on each route whose secrets are set; the rest 404 until
// Vault has them. It returns the flag Redis client for the caller to close.
func configureOptionalRoutes(s *server, logger *slog.Logger) *redis.Client {
	s.stripe = newStripeVerifier(getenv("STRIPE__ENDPOINT_SECRET"))
	if s.stripe == nil {
		logger.Warn("STRIPE__ENDPOINT_SECRET is not set, so /stripe-webhook is off")
	}
	s.stripeConnect = newStripeVerifier(getenv("STRIPE_CONNECT__ENDPOINT_SECRET"))
	if s.stripeConnect == nil {
		logger.Warn("STRIPE_CONNECT__ENDPOINT_SECRET is not set, so /stripe-connect-webhook is off")
	}

	var keys, names []string
	for _, name := range sendgridPublicKeyEnvVars {
		if key := getenv(name); !blank(key) {
			keys, names = append(keys, key), append(names, name)
		}
	}
	if len(keys) == 0 {
		logger.Warn("no SENDGRID_*_WEBHOOK_PUBLIC_KEY is set, so /sendgrid-webhook is off")
		return nil
	}
	// An unknown flag must not waive verification, so SendGrid needs the flag's Redis.
	redisHost := getenv("REDIS_HOST")
	if redisHost == "" {
		logger.Warn("REDIS_HOST is not set, so " + sendgridFlag + " can't be read and /sendgrid-webhook is off")
		return nil
	}
	client, err := newRedisClient(redisHost, flagPoolSize, flagTimeout)
	if err != nil {
		logger.Error("REDIS_HOST does not parse, so /sendgrid-webhook is off", "error", err.Error())
		return nil
	}
	s.sendgrid = newSendgridVerifier(keys)
	for i, key := range s.sendgrid.keys {
		if key.err != nil {
			logger.Warn(names[i]+" does not parse, so SendGrid verification fails once it reaches that key", "error", key.err.Error())
		}
	}
	s.sendgridFlag = newFlipperFlag(client, sendgridFlag)
	return client
}

func run(logger *slog.Logger) error {
	verifier, err := newSignatureVerifier(getenv("RESEND_WEBHOOK_SECRET"))
	if err != nil {
		return err
	}
	redisHost := getenv("SIDEKIQ_REDIS_HOST")
	if redisHost == "" {
		return errors.New("SIDEKIQ_REDIS_HOST is not set")
	}
	client, err := newRedisClient(redisHost, redisPoolSize, redisTimeout)
	if err != nil {
		return err
	}
	defer client.Close()
	// A wrong host must fail the task, so the zone roll restores the previous job,
	// instead of passing readiness and answering every webhook with a 500.
	if err := pingRedis(client, startupPingTimeout); err != nil {
		return err
	}

	headerKey := getenv("MAILER_HEADERS_ENCRYPTION_KEY_V1")
	if headerKey == "" {
		logger.Warn("MAILER_HEADERS_ENCRYPTION_KEY_V1 is not set, so no event can be filtered and every one is enqueued")
	}

	port := os.Getenv("PORT")
	if port == "" {
		port = defaultPort
	}
	s := &server{
		resend: verifier,
		filter: newEventFilter(headerKey),
		sns:    newSNSVerifier(newCertGetter()),
		queue:  &sidekiqQueue{client: client},
		logger: logger,
		now:    time.Now,
	}
	if roots, err := x509.SystemCertPool(); err != nil || roots.Equal(x509.NewCertPool()) {
		logger.Warn("no CA certificates are installed, so no SNS signing certificate can be fetched and every SNS message is rejected")
	}
	if flagClient := configureOptionalRoutes(s, logger); flagClient != nil {
		defer flagClient.Close()
	}
	httpServer := &http.Server{
		Addr:              ":" + port,
		Handler:           s.routes(),
		ReadHeaderTimeout: readHeaderTimeout,
		ReadTimeout:       requestTimeout,
		WriteTimeout:      requestTimeout,
		IdleTimeout:       idleTimeout,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	go s.reportCounts(ctx, countsInterval)

	serveErr := make(chan error, 1)
	go func() { serveErr <- httpServer.ListenAndServe() }()
	logger.Info("listening", "port", port)

	select {
	case err := <-serveErr:
		return err
	case <-ctx.Done():
	}
	shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancel()
	return httpServer.Shutdown(shutdownCtx)
}
