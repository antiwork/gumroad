package products

import (
	"encoding/json"
	"net/http"
	"reflect"
	"regexp"
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
		// Each other character is a dash, a combining mark too; İ's downcase adds one, and the
		// Kelvin sign's is a k.
		"Café Ünïcode":           "caf---n-code",
		"cafe\u0301":             "cafe-",
		"İstanbul":               "i-stanbul",
		"\u212Aelvin":            "kelvin",
		"日本":                     "--",
		strings.Repeat("İ", 101): strings.Repeat("i-", 100),
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
	path := "/l/guide?utm_source=News+Letter&utm_medium=email&utm_campaign=Caf%C3%A9&utm_term="
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
	want := map[string]any{"utm_source": "news-letter", "utm_medium": "email", "utm_campaign": "caf-", "utm_term": nil, "utm_content": nil}
	if !reflect.DeepEqual(visit["utm_params"], want) || visit["seller_id"] != float64(sellerID) || visit["target_resource_id"] != float64(productID) ||
		visit["target_resource_type"] != "product_page" || visit["browser_guid"] != "guid-1" || visit["referrer"] != "https://example.com/r" ||
		visit["user_agent"] != "UA" || visit["user_id"] != nil || visit["visited_at_us"] != float64(testNow.UnixMicro()) {
		t.Errorf("visit %v", visit)
	}
	if trail, _ := visit["paper_trail"].(map[string]any); trail["request_path"] != "/l/guide" || trail["request_uuid"] == "" {
		t.Errorf("paper_trail %v", trail)
	}
}

// A value that isn't a String goes to Rails, whose to_s of it this port doesn't build.
func TestAUTMTaggedVisitGoesToRails(t *testing.T) {
	for path, reason := range map[string]string{
		"/l/guide?utm_source[]=a&utm_medium=a&utm_campaign=b": "param utm_source",
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
	path := "/l/guide?utm_source=a&utm_medium=a"
	if w := e.get(host, path, e.dryRun(host, path, testNow)); strings.HasPrefix(w.Header().Get("X-Go-Web-Fallback"), "param utm") {
		t.Errorf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
}

// A visit needs Sidekiq; a banned product's is recorded before check_banned's 404.
func TestAUTMVisitOnABannedProduct(t *testing.T) {
	const tagged = "/l/guide?utm_source=a&utm_medium=b&utm_campaign=c"
	e := newTestEnv(t)
	conn := testdb.Open(t)
	if w := e.get(host, tagged, e.dryRun(host, tagged, testNow)); w.Header().Get("X-Go-Web-Fallback") != "utm visit push" {
		t.Errorf("no sidekiq: %d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
	jobs := miniredis.RunT(t)
	e.config.Page.Sidekiq = &sidekiq.Client{Redis: redis.NewClient(&redis.Options{Addr: jobs.Addr()}), RedisVersion: "7.2.4"}
	mustExec(t, conn, "UPDATE links SET banned_at = ? WHERE id = ?", testNow, productID)
	if w := e.get(host, tagged, e.dryRun(host, tagged, testNow.Add(time.Second))); w.Code != http.StatusNotFound || jobs.Exists("queue:default") {
		t.Errorf("dry run: %d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
	if w := e.get(host, tagged, map[string]string{"Cookie": "_gumroad_guid=guid"}); w.Code != http.StatusNotFound || e.railsHit != nil {
		t.Errorf("banned: %d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
	if queued, _ := jobs.List("queue:default"); len(queued) != 1 || !strings.Contains(queued[0], `"class":"RecordUtmLinkVisitJob"`) {
		t.Errorf("queue:default %v", queued)
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

// wanted=true's redirect to checkout follows the before_action, so it records the visit too.
func TestAUTMTaggedVisitThatGoesToCheckout(t *testing.T) {
	e := newTestEnv(t)
	testdb.Open(t)
	jobs := miniredis.RunT(t)
	e.config.Page.Sidekiq = &sidekiq.Client{Redis: redis.NewClient(&redis.Options{Addr: jobs.Addr()}), RedisVersion: "7.2.4"}
	w := e.get(host, "/l/guide?wanted=true&utm_source=a&utm_medium=b&utm_campaign=c", map[string]string{"Cookie": "_gumroad_guid=guid-1"})
	if w.Code != http.StatusFound || e.railsHit != nil {
		t.Fatalf("%d %q", w.Code, w.Header().Get("X-Go-Web-Fallback"))
	}
	if queued, _ := jobs.List("queue:default"); len(queued) != 1 || !strings.Contains(queued[0], `"class":"RecordUtmLinkVisitJob"`) {
		t.Errorf("queued %v", queued)
	}
}

// Rails routes HEAD to show and Rack::Head drops the body, so a HEAD gets the page's status and
// headers; track_utm_link_visit skips it.
func TestAHEADRequest(t *testing.T) {
	e := newTestEnv(t)
	testdb.Open(t)
	jobs := miniredis.RunT(t)
	e.config.Page.Sidekiq = &sidekiq.Client{Redis: redis.NewClient(&redis.Options{Addr: jobs.Addr()}), RedisVersion: "7.2.4"}
	path := "/l/guide?utm_source=a&utm_medium=b&utm_campaign=c"
	cookie := map[string]string{"Cookie": "_gumroad_guid=guid-1"}
	head := e.request(http.MethodHead, host, path, cookie)
	if head.Code != http.StatusOK || e.railsHit != nil || head.Body.Len() != 0 {
		t.Fatalf("%d %q, %d bytes", head.Code, head.Header().Get("X-Go-Web-Fallback"), head.Body.Len())
	}
	if list, _ := jobs.List("queue:default"); len(list) != 0 {
		t.Errorf("HEAD queued %v", list)
	}
	get := e.get(host, path, cookie)
	if list, _ := jobs.List("queue:default"); len(list) != 1 {
		t.Errorf("GET queued %v", list)
	}
	for _, h := range []string{"Content-Type", "Content-Length", "Vary", "Cache-Control", "Content-Security-Policy"} {
		got, want := head.Header().Get(h), get.Header().Get(h)
		if h == "Content-Security-Policy" {
			// Each response has its own nonce.
			got, want = nonceSrc.ReplaceAllString(got, ""), nonceSrc.ReplaceAllString(want, "")
		}
		if got != want || want == "" {
			t.Errorf("%s %q, GET's %q", h, got, want)
		}
	}
}

var nonceSrc = regexp.MustCompile(`'nonce-[^']*'`)
