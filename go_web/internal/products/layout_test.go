package products

import (
	"net/http"
	"reflect"
	"testing"

	"github.com/antiwork/gumroad/go_web/internal/session/testdb"
)

// layout=profile renders the product page props in the profile component, without the
// storefront's catalog unless the seller has one.
func TestTheProfileLayout(t *testing.T) {
	e := newTestEnv(t)
	testdb.Open(t)
	plain := e.get(host, "/l/guide", nil)
	profile := e.get(host, "/l/guide?layout=profile", nil)
	if plain.Code != http.StatusOK || profile.Code != http.StatusOK || e.railsHit != nil {
		t.Fatalf("%d %d %q", plain.Code, profile.Code, profile.Header().Get("X-Go-Web-Fallback"))
	}
	want, got := componentProps(t, plain.Body.String(), productComponent), componentProps(t, profile.Body.String(), storefrontComponent)
	// Each request has its own session.
	for _, props := range []map[string]any{want, got} {
		delete(props, "authenticity_token")
		delete(props, "csp_nonce")
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("profile props %v\nwant %v", got, want)
	}
}

// layout and recommended_by values this port leaves to Rails, and bare keys it doesn't.
func TestALayoutOrRecommendationParam(t *testing.T) {
	for query, reason := range map[string]string{
		"?layout=discover":               "layout discover",
		"?layout=embed":                  "param layout",
		"?recommended_by=search":         "discover search",
		"?recommended_by=discover":       "discover search",
		"?recommended_by[]=wishlist":     "param recommended_by",
		"?layout=profile&recommended_by": "",
		"?layout":                        "",
	} {
		t.Run(query, func(t *testing.T) {
			e := newTestEnv(t)
			testdb.Open(t)
			w := e.get(host, "/l/guide"+query, e.dryRun(host, "/l/guide"+query, testNow))
			if got := w.Header().Get("X-Go-Web-Fallback"); got != reason || reason == "" && w.Code != http.StatusOK {
				t.Errorf("%d %q, want %q", w.Code, got, reason)
			}
		})
	}
}
