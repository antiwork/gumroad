// Command resend_callbacks receives Resend webhooks on the callback fleet and enqueues
// HandleResendEventJob exactly as ForeignWebhooksController#resend does, without Rails.
package main

import (
	"context"
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
	defaultPort = "3000"
	// Inside the Nomad task's 30s kill_timeout.
	shutdownTimeout    = 25 * time.Second
	countsInterval     = time.Minute
	startupPingTimeout = 30 * time.Second
)

func pingRedis(client *redis.Client, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		err := client.Ping(ctx).Err()
		cancel()
		if err == nil {
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("Sidekiq Redis is unreachable: %w", err)
		}
		time.Sleep(time.Second)
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

func run(logger *slog.Logger) error {
	verifier, err := newSignatureVerifier(getenv("RESEND_WEBHOOK_SECRET"))
	if err != nil {
		return err
	}
	redisHost := getenv("SIDEKIQ_REDIS_HOST")
	if redisHost == "" {
		return errors.New("SIDEKIQ_REDIS_HOST is not set")
	}
	redisOptions, err := redis.ParseURL("redis://" + redisHost)
	if err != nil {
		return err
	}
	redisOptions.DialTimeout = 2 * time.Second
	redisOptions.ReadTimeout = 2 * time.Second
	redisOptions.WriteTimeout = 2 * time.Second
	redisOptions.PoolSize = 64
	client := redis.NewClient(redisOptions)
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
		verifier: verifier,
		filter:   newEventFilter(headerKey),
		queue:    &sidekiqQueue{client: client},
		logger:   logger,
		now:      time.Now,
	}
	httpServer := &http.Server{
		Addr:              ":" + port,
		Handler:           s.routes(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      30 * time.Second,
		// nginx expires its upstream keepalive sockets at 15s, so it never sends on
		// one this server is closing.
		IdleTimeout: 20 * time.Second,
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
