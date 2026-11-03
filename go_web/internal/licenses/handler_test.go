package licenses

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"
)

// These run without MySQL: every path here answers before the first query.

func TestRefusesNonStringIdentifiersLikeCleanParams(t *testing.T) {
	h := newHarness(t, nil, nil)

	w := h.form(t, "product_permalink=abc&license_key[foo]=bar")
	expectResponse(t, w, http.StatusBadRequest, `{"success":false,"message":"The 'license_key' parameter must be a string."}`)
	expectHeader(t, w, "Content-Type", "application/json; charset=utf-8")
	expectHeader(t, w, "Cache-Control", "no-cache")
	expectHeader(t, w, "Vary", "Origin")
	expectHeader(t, w, "ETag", "")

	w = h.do(t, request{contentType: "application/json", body: `{"product_id":{"foo":"bar"},"license_key":"x"}`, headers: map[string]string{"Accept": "application/json"}})
	expectResponse(t, w, http.StatusBadRequest, `{"success":false,"message":"The 'product_id' parameter must be a string."}`)
	expectHeader(t, w, "Vary", "Accept, Origin")

	// The first failing key in clean_params' order wins, and the query string beats the body.
	w = h.do(t, request{target: "/v2/licenses/verify?link_id[]=1", contentType: "application/json", body: `{"id":5,"license_key":"x","link_id":"ok"}`})
	expectResponse(t, w, http.StatusBadRequest, `{"success":false,"message":"The 'id' parameter must be a string."}`)
	w = h.do(t, request{target: "/v2/licenses/verify?link_id[]=1", contentType: "application/json", body: `{"license_key":"x","link_id":"ok"}`})
	expectResponse(t, w, http.StatusBadRequest, `{"success":false,"message":"The 'link_id' parameter must be a string."}`)
}

func TestRoutesOnlyWhereRailsMountsTheAction(t *testing.T) {
	h := newHarness(t, nil, nil)
	bad := "license_key[x]=1"
	for _, c := range []struct {
		host, target string
		status       int
	}{
		{"api.gumroad.com", "/v2/licenses/verify", 400},
		{"api.gumroad.com", "/v2/licenses/verify.json", 400},
		{"api.gumroad.com", "/v2/licenses/verify.xml", 400},
		{"gumroad.com", "/api/v2/licenses/verify", 400},
		{"app.gumroad.com", "/api/v2/licenses/verify.json", 400},
		{"api.gumroad.com", "/v2/licenses/verify/", 404},
		{"api.gumroad.com", "/v2/licenses/verify.", 404},
		{"api.gumroad.com", "/api/v2/licenses/verify", 404},
		{"gumroad.com", "/v2/licenses/verify", 404},
		{"seller.gumroad.com", "/api/v2/licenses/verify", 404},
		{"api.gumroad.com", "/v2/licenses/verify.json.xml", 404},
		{"api.gumroad.com", "/v2/licenses/verifyx", 404},
		{"api.gumroad.com", "/v2/licenses/enable", 404},
	} {
		w := h.do(t, request{host: c.host, target: c.target, contentType: "application/x-www-form-urlencoded", body: bad})
		if w.Code != c.status {
			t.Errorf("%s%s: status %d, want %d", c.host, c.target, w.Code, c.status)
		}
	}
	// An unrouted path gets the public 404 page, as RoutingError does.
	if body := readBody(t, h.do(t, request{target: "/v2/licenses/enable", contentType: "application/x-www-form-urlencoded"})); !strings.Contains(body, "Page not found") {
		t.Errorf("404 body = %.80q", body)
	}
	w := h.form(t, bad)
	expectHeader(t, w, "X-Revision", "rev")
	expectHeader(t, w, "X-Content-Type-Options", "nosniff")
}

func TestAnswersUnparseableRequestsLikeTheRackStack(t *testing.T) {
	h := newHarness(t, nil, nil)

	w := h.form(t, "license_key=%zz")
	expectResponse(t, w, http.StatusBadRequest, "")
	expectHeader(t, w, "Content-Type", "text/html")

	w = h.do(t, request{contentType: "application/json", body: `{"license_key":`, headers: map[string]string{"Accept": "application/json"}})
	expectResponse(t, w, http.StatusBadRequest, `{"status":400,"error":"Bad Request"}`)

	w = h.do(t, request{contentType: "text", body: "license_key=x"})
	expectResponse(t, w, http.StatusNotAcceptable, "")

	// Verify bodies are a few hundred bytes; 64 KiB is the cap.
	w = h.do(t, request{contentType: "application/x-www-form-urlencoded", body: "license_key[x]=1&pad=" + strings.Repeat("a", maxBodyBytes)})
	expectResponse(t, w, http.StatusRequestEntityTooLarge, "")
	w = h.do(t, request{contentType: "application/x-www-form-urlencoded", body: "license_key[x]=1&pad=" + strings.Repeat("a", maxBodyBytes-len("license_key[x]=1&pad="))})
	if w.Code != http.StatusBadRequest {
		t.Fatalf("a body at the cap is read: %d", w.Code)
	}
}

// JSON.parse's max_nesting is 100, and json 2.13 only counts a level that holds a value;
// the shared parser enforces it, and the action sees the 400.
func TestRefusesJSONNestedPastRubysLimit(t *testing.T) {
	h := newHarness(t, nil, nil)
	nested := func(depth int, inner string) string {
		return `{"license_key":5,"x":` + strings.Repeat("[", depth-1) + inner + strings.Repeat("]", depth-1) + `}`
	}
	accept := map[string]string{"Accept": "application/json"}
	mustString := `{"success":false,"message":"The 'license_key' parameter must be a string."}`
	tooDeep := `{"status":400,"error":"Bad Request"}`
	for _, c := range []struct {
		body string
		want string
	}{
		{nested(100, "1"), mustString},
		{nested(101, ""), mustString},
		{nested(101, "1"), tooDeep},
		{nested(102, ""), tooDeep},
		{`{"license_key":5,"x":"` + strings.Repeat("[", 200) + `"}`, mustString},
	} {
		w := h.do(t, request{contentType: "application/json; charset=utf-8", body: c.body, headers: accept})
		if got := readBody(t, w); got != c.want {
			t.Errorf("%.40s...: got %s", c.body, got)
		}
	}
}

func TestSendsRackCorsHeadersOnTheAPIHostOnly(t *testing.T) {
	h := newHarness(t, nil, nil)
	origin := map[string]string{"Origin": "https://seller.example.com"}

	w := h.do(t, request{contentType: "application/x-www-form-urlencoded", body: "id[]=1", headers: origin})
	expectHeader(t, w, "Access-Control-Allow-Origin", "*")
	expectHeader(t, w, "Access-Control-Allow-Methods", "GET, POST, PUT, DELETE")
	expectHeader(t, w, "Vary", "Origin")

	w = h.do(t, request{host: "gumroad.com", target: "/api/v2/licenses/verify", contentType: "application/x-www-form-urlencoded", body: "id[]=1", headers: origin})
	expectHeader(t, w, "Access-Control-Allow-Origin", "")

	preview := newHarness(t, nil, map[string]string{"RAILS_ENV": "staging", "CUSTOM_DOMAIN": "pr-1.apps.example.com"})
	w = preview.do(t, request{host: "pr-1.apps.example.com", target: "/api/v2/licenses/verify", contentType: "application/x-www-form-urlencoded", body: "id[]=1",
		headers: map[string]string{"Origin": "https://pr-1.apps.example.com"}})
	expectHeader(t, w, "Access-Control-Allow-Origin", "https://pr-1.apps.example.com")
	expectHeader(t, w, "Access-Control-Allow-Credentials", "true")
}

func TestProductIDFlagsFallBackToTheLastRead(t *testing.T) {
	h := newHarness(t, nil, nil)
	ctx := context.Background()
	flags := func(productID int64) (bool, *time.Time) {
		t.Helper()
		skip, cutoff, err := h.handler.productIDFlags(ctx, productID, testNow)
		if err != nil {
			t.Fatal(err)
		}
		return skip, cutoff
	}

	if skip, cutoff := flags(1); skip || cutoff != nil {
		t.Fatalf("unset: %v %v", skip, cutoff)
	}
	// Production writes the cutoff as Time#to_s.
	h.redis.Set(forceProductIDTimestampKey, "2026-10-01 00:00:00 UTC")
	if _, cutoff := flags(1); cutoff == nil || !cutoff.Equal(time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)) {
		t.Fatalf("set: %v", cutoff)
	}
	h.redis.SetError("READONLY stalled")
	if skip, cutoff := flags(1); skip || cutoff == nil {
		t.Fatal("an unread skip flag keeps the check, and an unread cutoff keeps the last enforcement")
	}
	h.redis.SetError("")
	h.redis.Del(forceProductIDTimestampKey)
	if _, cutoff := flags(1); cutoff != nil {
		t.Fatal("a removed cutoff reads as nil")
	}
	h.redis.SetError("READONLY stalled")
	if _, cutoff := flags(1); cutoff != nil {
		t.Fatal("a stall must not restore a cutoff the operator removed")
	}
	h.redis.SetError("")

	// Rails never reads the cutoff for a skipped product, so that read can't refresh the last one.
	h.redis.Set(skipProductIDCheckPrefix+"7", "true")
	h.redis.Set(forceProductIDTimestampKey, "2026-10-01 00:00:00 UTC")
	if skip, _ := flags(7); !skip {
		t.Fatal("skip flag")
	}
	h.redis.SetError("READONLY stalled")
	if _, cutoff := flags(8); cutoff != nil {
		t.Fatal("the skipped product's request must not have updated the last-known cutoff")
	}
	h.redis.SetError("")

	h.redis.Set(forceProductIDTimestampKey, "garbage")
	if _, _, err := h.handler.productIDFlags(ctx, 8, testNow); err == nil {
		t.Fatal("an unparseable timestamp raises in Rails")
	}
}

func TestMatchesPermalinkIgnoresCase(t *testing.T) {
	prod := &product{uniquePermalink: nullStr("abcdef"), customPermalink: nullStr("Max-1")}
	for permalink, want := range map[string]bool{"ABCDEF": true, "max-1": true, "max": false, "": false} {
		if got := matchesPermalink(prod, permalink); got != want {
			t.Errorf("matchesPermalink(%q) = %v", permalink, got)
		}
	}
}
