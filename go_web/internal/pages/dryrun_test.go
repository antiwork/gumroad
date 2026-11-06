package pages

import (
	"net/http/httptest"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"
)

func TestDryRunsNeedASecretAValidHeaderAndOneUse(t *testing.T) {
	if DryRunKey("") != nil || DryRunKey("  ") != nil {
		t.Fatal("a blank secret made a key")
	}
	now := time.Unix(1_800_000_000, 0)
	key := DryRunKey("secret")
	c := &Controller{DryRunKey: key, Now: func() time.Time { return now },
		DryRunOnce: redis.NewClient(&redis.Options{Addr: miniredis.RunT(t).Addr()})}
	state := func(host, target, header string) dryRunState {
		r := httptest.NewRequest("GET", target, nil)
		r.Host = host
		r.Header.Set(dryRunHeader, header)
		return c.dryRunState(r)
	}
	req := func(host, target, header string) bool { return state(host, target, header) == dryRunValid }
	sign := func(host, target string, at time.Time) string { return SignDryRun(key, "GET", host, target, at) }

	if !req("a.gumroad.com", "/l/x?y=1", sign("a.gumroad.com", "/l/x?y=1", now)) {
		t.Fatal("a valid header was refused")
	}
	// A used header is refused outright, so its request writes nothing either.
	if got := state("a.gumroad.com", "/l/x?y=1", sign("a.gumroad.com", "/l/x?y=1", now)); got != dryRunRefused {
		t.Errorf("a used header: %v", got)
	}
	for name, ok := range map[string]bool{
		"another host":  req("b.gumroad.com", "/l/x", sign("a.gumroad.com", "/l/x", now)),
		"another query": req("a.gumroad.com", "/l/x?y=2", sign("a.gumroad.com", "/l/x?y=1", now.Add(time.Second))),
		"too old":       req("a.gumroad.com", "/l/x", sign("a.gumroad.com", "/l/x", now.Add(-2*time.Minute))),
		"too new":       req("a.gumroad.com", "/l/x", sign("a.gumroad.com", "/l/x", now.Add(time.Minute))),
		"another key":   req("a.gumroad.com", "/l/z", SignDryRun(DryRunKey("other"), "GET", "a.gumroad.com", "/l/z", now)),
	} {
		if ok {
			t.Errorf("%s: honored", name)
		}
	}
	c.DryRunOnce = nil
	if req("a.gumroad.com", "/l/w", sign("a.gumroad.com", "/l/w", now)) {
		t.Error("honored without a store")
	}
}
