package main

import (
	"io"
	"log/slog"
	"strings"
	"testing"

	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"

	"github.com/antiwork/gumroad/go_web/internal/web"
)

func testDependencies(t *testing.T) (*web.App, *dependencies) {
	t.Helper()
	env, err := web.LoadEnvironment(func(name string) string {
		return map[string]string{"RAILS_ENV": "production", "REVISION": "r"}[name]
	})
	if err != nil {
		t.Fatal(err)
	}
	client := redis.NewClient(&redis.Options{Addr: miniredis.RunT(t).Addr()})
	t.Cleanup(func() { client.Close() })
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	deps := &dependencies{env: env, logger: logger, redis: client}
	t.Cleanup(deps.close)
	return web.NewApp(env, logger, client), deps
}

func TestRegisterRouteGroupsRefusesAnUnknownGroup(t *testing.T) {
	app, deps := testDependencies(t)
	err := registerRouteGroups(app, deps, "robots, robotz")
	if err == nil || !strings.Contains(err.Error(), `"robotz"`) {
		t.Fatalf("err = %v", err)
	}
}

func TestAnEnabledGroupFailsStartupWithoutItsConfig(t *testing.T) {
	t.Setenv("SIDEKIQ_REDIS_HOST", "")
	app, deps := testDependencies(t)
	err := registerRouteGroups(app, deps, "beacons")
	if err == nil || !strings.Contains(err.Error(), "SIDEKIQ_REDIS_HOST is not set") {
		t.Fatalf("err = %v", err)
	}
}
