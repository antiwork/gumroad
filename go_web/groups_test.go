package main

import (
	"io"
	"log/slog"
	"os"
	"strings"
	"testing"

	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"

	"github.com/antiwork/gumroad/go_web/internal/obfuscate"
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

func TestRegisterRouteGroupsRefusesARepeatedGroup(t *testing.T) {
	app, deps := testDependencies(t)
	err := registerRouteGroups(app, deps, "robots,robots")
	if err == nil || !strings.Contains(err.Error(), `"robots" is listed twice`) {
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

const (
	testCredentialsPath = "internal/credentials/testdata/test.yml.enc"
	testMasterKey       = "0123456789abcdef0123456789abcdef"
)

// unsetenv clears name for one test; t.Setenv can only set.
func unsetenv(t *testing.T, name string) {
	t.Helper()
	t.Setenv(name, "")
	os.Unsetenv(name)
}

func credentialsDependencies(t *testing.T) *dependencies {
	t.Helper()
	t.Setenv("RAILS_CREDENTIALS_PATH", testCredentialsPath)
	t.Setenv("RAILS_MASTER_KEY", testMasterKey)
	secrets, err := loadCredentials()
	if err != nil {
		t.Fatal(err)
	}
	_, deps := testDependencies(t)
	deps.credentials = secrets
	return deps
}

func TestConfigReadsTheEnvironmentBeforeTheCredentials(t *testing.T) {
	deps := credentialsDependencies(t)

	unsetenv(t, "STRIPE__ENDPOINT_SECRET")
	if got := deps.config("STRIPE__ENDPOINT_SECRET"); got != "whsec_test" {
		t.Errorf("unset: %q", got)
	}
	t.Setenv("STRIPE__ENDPOINT_SECRET", "from-env")
	if got := deps.config("STRIPE__ENDPOINT_SECRET"); got != "from-env" {
		t.Errorf("set: %q", got)
	}
	// ENV.fetch returns a blank value rather than falling back.
	t.Setenv("STRIPE__ENDPOINT_SECRET", "")
	if got := deps.config("STRIPE__ENDPOINT_SECRET"); got != "" {
		t.Errorf("blank: %q", got)
	}
	t.Setenv("STRIPE__ENDPOINT_SECRET", "<no value>")
	if got := deps.config("STRIPE__ENDPOINT_SECRET"); got != "whsec_test" {
		t.Errorf("consul-template's missing key: %q", got)
	}
	// GlobalConfig.get ends in presence.
	t.Setenv("STRIPE__ENDPOINT_SECRET", "  ")
	if got := deps.config("STRIPE__ENDPOINT_SECRET"); got != "" {
		t.Errorf("whitespace: %q", got)
	}
	unsetenv(t, "MISSING")
	if got := deps.config("MISSING"); got != "" {
		t.Errorf("missing: %q", got)
	}
}

func TestObfuscatedIDsComeFromTheCredentials(t *testing.T) {
	unsetenv(t, "OBFUSCATE_IDS_CIPHER_KEY")
	unsetenv(t, "OBFUSCATE_IDS_NUMERIC_CIPHER_KEY")
	ids, err := credentialsDependencies(t).obfuscatedIDs()
	if err != nil {
		t.Fatal(err)
	}
	// The fixture's two keys, so a lookup that dropped either changes these.
	want, err := obfuscate.New("quoted: value", "123456789")
	if err != nil {
		t.Fatal(err)
	}
	gotNumeric, _ := ids.EncryptNumeric(42)
	wantNumeric, _ := want.EncryptNumeric(42)
	if ids.Encrypt(42) != want.Encrypt(42) || gotNumeric != wantNumeric {
		t.Errorf("ids = %q/%d, want %q/%d", ids.Encrypt(42), gotNumeric, want.Encrypt(42), wantNumeric)
	}
	_, withoutCredentials := testDependencies(t)
	if _, err := withoutCredentials.obfuscatedIDs(); err == nil || !strings.Contains(err.Error(), "OBFUSCATE_IDS_CIPHER_KEY is not set") {
		t.Fatalf("err = %v", err)
	}
}

func TestLoadCredentials(t *testing.T) {
	unsetenv(t, "RAILS_CREDENTIALS_PATH")
	if secrets, err := loadCredentials(); secrets != nil || err != nil {
		t.Errorf("unset path: %v, %v", secrets, err)
	}
	t.Setenv("RAILS_CREDENTIALS_PATH", testCredentialsPath)
	unsetenv(t, "RAILS_MASTER_KEY")
	if _, err := loadCredentials(); err == nil || !strings.Contains(err.Error(), "RAILS_MASTER_KEY must be") {
		t.Errorf("no key: %v", err)
	}
	t.Setenv("RAILS_MASTER_KEY", strings.Repeat("ab", 16))
	if _, err := loadCredentials(); err == nil || !strings.Contains(err.Error(), "RAILS_CREDENTIALS_PATH: ") || !strings.Contains(err.Error(), "does not decrypt") {
		t.Errorf("wrong key: %v", err)
	}
}
