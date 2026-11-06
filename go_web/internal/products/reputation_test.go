package products

import (
	"html"
	"net/http"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"

	"github.com/antiwork/gumroad/go_web/internal/sidekiq"
)

func TestAStaleReputationSnapshotQueuesItsRefresh(t *testing.T) {
	stale := strconv.FormatInt(testNow.Add(-time.Hour).Unix(), 10)
	for _, c := range []struct {
		name, snapshot, version string
		reputation              string
	}{
		// Old but current: it still renders, and the refresh is queued.
		{"an old snapshot", `{"aggregate":[3,30,120],"signature":2,"computed_at":` + stale + `}`, "2", `"seller_reputation":{`},
		// Behind the version: nothing renders until the refresh lands.
		{"a snapshot behind the version", `{"aggregate":[3,30,120],"signature":1,"computed_at":` + stale + `}`, "2", `"seller_reputation":null`},
		{"no snapshot", "", "", `"seller_reputation":null`},
	} {
		t.Run(c.name, func(t *testing.T) {
			e := newTestEnv(t)
			jobs := miniredis.RunT(t)
			e.config.Page.Sidekiq = &sidekiq.Client{Redis: redis.NewClient(&redis.Options{Addr: jobs.Addr()}), RedisVersion: "7.2.4"}
			e.redis.HSet("seller_reputation_summary", "boolean", "true")
			if c.snapshot != "" {
				e.redis.Set("seller_reputation_summary/v2/snapshot/1790001", c.snapshot)
				e.redis.Set("seller_reputation_summary/version/1790001", c.version)
			}
			// A dry run renders it and queues nothing.
			if w := e.get(host, "/l/guide", e.dryRun(host, "/l/guide", testNow)); w.Code != http.StatusOK {
				t.Fatalf("dry run: %d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
			}
			if jobs.Exists("queue:low") {
				t.Fatal("a dry run queued the refresh")
			}
			w := e.get(host, "/l/guide", nil)
			if w.Code != http.StatusOK {
				t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
			}
			if page := html.UnescapeString(dataPage.FindStringSubmatch(w.Body.String())[1]); !strings.Contains(page, c.reputation) {
				t.Errorf("want %s", c.reputation)
			}
			queued, _ := jobs.List("queue:low")
			if len(queued) != 1 || !strings.Contains(queued[0], `"args":[1790001],"class":"WarmSellerReputationSummaryJob"`) {
				t.Errorf("queue:low %v", queued)
			}
			// The lock holds while that job waits, so the next view queues nothing more.
			e.get(host, "/l/guide", nil)
			if queued, _ := jobs.List("queue:low"); len(queued) != 1 {
				t.Errorf("%d jobs queued", len(queued))
			}
		})
	}
}

func TestAReputationRefreshWithoutSidekiqGoesToRails(t *testing.T) {
	e := newTestEnv(t)
	e.redis.HSet("seller_reputation_summary", "boolean", "true")
	if w := e.get(host, "/l/guide", e.dryRun(host, "/l/guide", testNow)); w.Header().Get("X-Go-Web-Fallback") != "reputation snapshot refresh" {
		t.Errorf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
}

func TestAFailedReputationPushGoesToRails(t *testing.T) {
	e := newTestEnv(t)
	jobs := miniredis.RunT(t)
	e.config.Page.Sidekiq = &sidekiq.Client{Redis: redis.NewClient(&redis.Options{Addr: jobs.Addr(), MaxRetries: -1}), RedisVersion: "7.2.4"}
	jobs.Close()
	e.redis.HSet("seller_reputation_summary", "boolean", "true")
	if e.get(host, "/l/guide", nil); e.railsHit == nil || len(e.cache.writes) != 0 {
		t.Errorf("rails %v, cache writes %v", e.railsHit != nil, e.cache.writes)
	}
}
