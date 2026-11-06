package oauth

import (
	"context"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/session"
	"github.com/antiwork/gumroad/go_web/internal/session/testdb"
	"github.com/antiwork/gumroad/go_web/internal/web"
)

func TestFromRequestFollowsDoorkeepersMethodOrder(t *testing.T) {
	params := map[string]any{"access_token": "param", "bearer_token": "bearer"}
	get := func(name string) any { return params[name] }
	for header, want := range map[string]string{
		"Bearer header": "header", "bearer header": "header", "Bearer   ": "param", "Basic abc": "param", "": "param",
	} {
		if got, ok := FromRequest(header, get); !ok || got != want {
			t.Errorf("FromRequest(%q) = %q, want %q", header, got, want)
		}
	}
	if got, _ := FromRequest("", func(name string) any { return map[string]any{"access_token": " ", "bearer_token": "b"}[name] }); got != "b" {
		t.Errorf("a blank access_token falls through to bearer_token, got %q", got)
	}
	// A present non-String still wins, and matches no stored token.
	if got, ok := FromRequest("", func(name string) any { return map[string]any{"access_token": []any{"x"}, "bearer_token": "b"}[name] }); ok {
		t.Errorf("got %q %v", got, ok)
	}
	if _, ok := FromRequest("", func(string) any { return nil }); ok {
		t.Error("no credential")
	}
}

func TestTokenValidity(t *testing.T) {
	now := time.Date(2026, 11, 2, 10, 0, 0, 0, time.UTC)
	hour := int64(3600)
	past := now.Add(-time.Second)
	future := now.Add(time.Second)
	for name, c := range map[string]struct {
		token      Token
		accessible bool
	}{
		"plain":           {Token{CreatedAt: now.Add(-48 * time.Hour)}, true},
		"expired":         {Token{CreatedAt: now.Add(-2 * time.Hour), ExpiresIn: &hour}, false},
		"not yet expired": {Token{CreatedAt: now.Add(-30 * time.Minute), ExpiresIn: &hour}, true},
		"revoked":         {Token{CreatedAt: now, RevokedAt: &past}, false},
		"revoked later":   {Token{CreatedAt: now, RevokedAt: &future}, true},
	} {
		if got := c.token.Accessible(now); got != c.accessible {
			t.Errorf("%s: accessible = %v", name, got)
		}
	}
	token := Token{Scopes: "creator_api mobile_api"}
	if !token.IncludesScope("mobile_api") || token.IncludesScope("view_sales") || !token.IncludesScope() {
		t.Error("includes_scope? is any-of, and true for none")
	}
}

func TestAuthorizeRendersDoorkeepersHeadErrors(t *testing.T) {
	now := time.Date(2026, 11, 2, 10, 0, 0, 0, time.UTC)
	past := now.Add(-time.Hour)
	for name, c := range map[string]struct {
		token       *Token
		status      int
		description string
	}{
		"missing":     {nil, 401, "The access token is invalid"},
		"revoked":     {&Token{CreatedAt: past, RevokedAt: &past, Scopes: "mobile_api"}, 401, "The access token was revoked"},
		"wrong scope": {&Token{CreatedAt: past, Scopes: "view_sales", ResourceOwnerID: new(int64)}, 403, ""},
		"no owner":    {&Token{CreatedAt: past, Scopes: "mobile_api"}, 401, "The access token is invalid"},
	} {
		w := httptest.NewRecorder()
		if Authorize(w, jsonRequest(now), c.token, "mobile_api") {
			t.Fatalf("%s: authorized", name)
		}
		if w.Code != c.status || w.Body.Len() != 0 || w.Header().Get("Cache-Control") != "no-store" || w.Header().Get("Content-Type") != "application/json" {
			t.Errorf("%s: %d %v", name, w.Code, w.Header())
		}
		want := ""
		if c.description != "" {
			want = `Bearer realm="Doorkeeper", error="invalid_token", error_description="` + c.description + `"`
		}
		if got := w.Header().Get("WWW-Authenticate"); got != want {
			t.Errorf("%s: WWW-Authenticate = %q", name, got)
		}
	}
	owner := int64(1)
	if !Authorize(httptest.NewRecorder(), jsonRequest(now), &Token{CreatedAt: past, Scopes: "mobile_api", ResourceOwnerID: &owner}, "mobile_api") {
		t.Error("a live token with the scope passes")
	}
}

func TestBoundAppliesApplicationControllersTokenRules(t *testing.T) {
	conn := testdb.Open(t)
	users := &session.Users{DB: conn}
	store := &Store{DB: conn, Users: users}
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Second)
	created := now.Add(-time.Hour)

	testdb.User(t, conn, 1_500_201, nil)                                                        // brand owner
	testdb.User(t, conn, 1_500_202, nil)                                                        // admin member
	testdb.User(t, conn, 1_500_203, map[string]any{"last_active_sessions_invalidated_at": now}) // member who signed out everywhere
	membership := func(id, user int64, role string, deleted any) {
		testdb.Insert(t, conn, "team_memberships", map[string]any{"id": id, "seller_id": 1_500_201, "user_id": user, "role": role,
			"created_at": now, "updated_at": now, "deleted_at": deleted})
	}
	membership(1_500_201, 1_500_202, "admin", nil)
	membership(1_500_202, 1_500_202, "marketing", nil)
	membership(1_500_203, 1_500_203, "admin", nil)
	token := func(id int64, value string, extra map[string]any) {
		row := map[string]any{"id": id, "resource_owner_id": 1_500_201, "application_id": 1, "token": value, "scopes": "mobile_api", "created_at": created}
		for k, v := range extra {
			row[k] = v
		}
		testdb.Insert(t, conn, "oauth_access_tokens", row)
	}
	token(1_500_201, "goweb-plain", nil)
	token(1_500_202, "goweb-brand", map[string]any{"team_membership_id": 1_500_201})
	token(1_500_203, "goweb-marketing", map[string]any{"team_membership_id": 1_500_202})
	token(1_500_204, "goweb-signed-out", map[string]any{"team_membership_id": 1_500_203})
	token(1_500_205, "goweb-mcp", map[string]any{"resource": "https://gumroad.com/claude/v1/mcp"})

	resource := "https://gumroad.com/mobile/media_locations"
	for raw, want := range map[string]bool{
		"goweb-plain": true, "GOWEB-PLAIN": true, "goweb-brand": true, "goweb-marketing": false,
		"goweb-signed-out": false, "goweb-mcp": false, "goweb-missing": false,
	} {
		got, err := store.Bound(ctx, raw, resource, now)
		if err != nil {
			t.Fatal(err)
		}
		if (got != nil) != want {
			t.Errorf("%s: bound = %v, want %v", raw, got != nil, want)
		}
	}
	if got, _ := store.Bound(ctx, "goweb-mcp", "https://gumroad.com/claude/v1/mcp", now); got == nil {
		t.Error("an MCP token is valid on its own resource")
	}

	brand, _ := store.Bound(ctx, "goweb-brand", resource, now)
	if actor, err := brand.Actor(); err != nil || actor.ID != 1_500_202 || brand.Owner.ID != 1_500_201 {
		t.Errorf("a brand token acts as its member, got %v %v", actor, err)
	}
	plain, _ := store.Bound(ctx, "goweb-plain", resource, now)
	if actor, err := plain.Actor(); err != nil || actor.ID != 1_500_201 {
		t.Errorf("a plain token acts as its owner, got %v %v", actor, err)
	}
	orphan := &Token{ResourceOwnerID: ptr(1_999_997)}
	if _, err := orphan.Actor(); err != ErrOwnerNotFound {
		t.Errorf("a missing owner is RecordNotFound, got %v", err)
	}
}

func ptr(n int64) *int64 { return &n }

func jsonRequest(now time.Time) *rails.Request {
	env, _ := web.LoadEnvironment(func(name string) string {
		return map[string]string{"RAILS_ENV": "production", "REVISION": "r"}[name]
	})
	r := httptest.NewRequest("POST", "/mobile/media_locations", nil)
	r.Header.Set("Accept", "application/json")
	req, err := rails.NewStack(env, "").Parse(r, nil, now)
	if err != nil {
		panic(err)
	}
	return req
}
