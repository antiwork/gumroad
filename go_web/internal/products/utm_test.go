package products

import (
	"encoding/json"
	"net/http"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"

	"github.com/antiwork/gumroad/go_web/internal/session/testdb"
	"github.com/antiwork/gumroad/go_web/internal/sidekiq"
)

func TestNormalizeUTMParam(t *testing.T) {
	for in, want := range map[string]any{
		"  Spring Sale!\t":       "spring-sale-",
		"news_letter-2":          "news_letter-2",
		"\x00 ":                  nil,
		strings.Repeat("a", 250): strings.Repeat("a", 200),
	} {
		if got := normalizeUTMParam(in); got != want {
			t.Errorf("%q: %v, want %v", in, got, want)
		}
	}
}

// A UTM-tagged visit is recorded as track_utm_link_visit records it, through
// RecordUtmLinkVisitJob, and not on a dry run or without the browser's cookie.
func TestAUTMTaggedVisit(t *testing.T) {
	e := newTestEnv(t)
	testdb.Open(t)
	jobs := miniredis.RunT(t)
	e.config.Page.Sidekiq = &sidekiq.Client{Redis: redis.NewClient(&redis.Options{Addr: jobs.Addr()}), RedisVersion: "7.2.4"}
	path := "/l/guide?utm_source=News+Letter&utm_medium=email&utm_campaign=Fall&utm_term="
	queued := func() []string {
		list, _ := jobs.List("queue:default")
		return list
	}

	e.get(host, path, e.dryRun(host, path, testNow))
	if q := queued(); len(q) != 0 {
		t.Errorf("a dry run queued %v", q)
	}
	w := e.get(host, path, map[string]string{"Cookie": "_gumroad_guid=guid-1", "Referer": "https://example.com/r", "User-Agent": "UA"})
	if w.Code != http.StatusOK || e.railsHit != nil {
		t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
	q := queued()
	if len(q) != 1 {
		t.Fatalf("queued %v", q)
	}
	var job struct {
		Class string           `json:"class"`
		Args  []map[string]any `json:"args"`
	}
	if err := json.Unmarshal([]byte(q[0]), &job); err != nil || job.Class != "RecordUtmLinkVisitJob" || len(job.Args) != 1 {
		t.Fatalf("job %s", q[0])
	}
	visit := job.Args[0]
	want := map[string]any{"utm_source": "news-letter", "utm_medium": "email", "utm_campaign": "fall", "utm_term": nil, "utm_content": nil}
	if !reflect.DeepEqual(visit["utm_params"], want) || visit["seller_id"] != float64(sellerID) || visit["target_resource_id"] != float64(productID) ||
		visit["target_resource_type"] != "product_page" || visit["browser_guid"] != "guid-1" || visit["referrer"] != "https://example.com/r" ||
		visit["user_agent"] != "UA" || visit["user_id"] != nil || visit["visited_at_us"] != float64(testNow.UnixMicro()) {
		t.Errorf("visit %v", visit)
	}
	if trail, _ := visit["paper_trail"].(map[string]any); trail["request_path"] != "/l/guide" || trail["request_uuid"] == "" {
		t.Errorf("paper_trail %v", trail)
	}
}

// The values this port doesn't normalize as Rails does, and a banned product's 404, go to Rails.
func TestAUTMTaggedVisitGoesToRails(t *testing.T) {
	for path, reason := range map[string]string{
		"/l/guide?utm_source=caf%C3%A9&utm_medium=a&utm_campaign=b":    "param utm_source",
		"/l/guide?utm_source[]=a&utm_medium=a&utm_campaign=b":          "param utm_source",
		"/l/guide?utm_source=a&utm_medium=a&utm_campaign=b&utm_term=ß": "param utm_term",
	} {
		t.Run(path, func(t *testing.T) {
			e := newTestEnv(t)
			testdb.Open(t)
			if w := e.get(host, path, e.dryRun(host, path, testNow)); w.Header().Get("X-Go-Web-Fallback") != reason {
				t.Errorf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
			}
		})
	}
	// Without all three, nothing's recorded and the page is go_web's.
	e := newTestEnv(t)
	testdb.Open(t)
	path := "/l/guide?utm_source=caf%C3%A9&utm_medium=a"
	if w := e.get(host, path, e.dryRun(host, path, testNow)); strings.HasPrefix(w.Header().Get("X-Go-Web-Fallback"), "param utm") {
		t.Errorf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
}

// A banned product's visit is recorded before check_banned's 404, and a visit needs Sidekiq.
func TestAUTMVisitThisPortCantRecord(t *testing.T) {
	const tagged = "/l/guide?utm_source=a&utm_medium=b&utm_campaign=c"
	e := newTestEnv(t)
	conn := testdb.Open(t)
	if w := e.get(host, tagged, e.dryRun(host, tagged, testNow)); w.Header().Get("X-Go-Web-Fallback") != "utm visit push" {
		t.Errorf("no sidekiq: %d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
	e.config.Page.Sidekiq = &sidekiq.Client{Redis: redis.NewClient(&redis.Options{Addr: miniredis.RunT(t).Addr()}), RedisVersion: "7.2.4"}
	mustExec(t, conn, "UPDATE links SET banned_at = ? WHERE id = ?", testNow, productID)
	if w := e.get(host, tagged, e.dryRun(host, tagged, testNow.Add(time.Second))); w.Header().Get("X-Go-Web-Fallback") != "utm visit on a banned product" {
		t.Errorf("banned: %d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
}

// A push that fails goes to Rails before anything is written.
func TestAFailedUTMVisitPushGoesToRails(t *testing.T) {
	e := newTestEnv(t)
	testdb.Open(t)
	jobs := miniredis.RunT(t)
	e.config.Page.Sidekiq = &sidekiq.Client{Redis: redis.NewClient(&redis.Options{Addr: jobs.Addr(), MaxRetries: -1}), RedisVersion: "7.2.4"}
	jobs.Close()
	if e.get(host, "/l/guide?utm_source=a&utm_medium=b&utm_campaign=c", nil); e.railsHit == nil || len(e.cache.writes) != 0 {
		t.Errorf("rails %v, cache writes %v", e.railsHit != nil, e.cache.writes)
	}
}
