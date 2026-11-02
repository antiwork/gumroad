package session

import (
	"context"
	"encoding/json"
	"strconv"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"

	"github.com/antiwork/gumroad/go_web/internal/session/sessiontest"
	"github.com/antiwork/gumroad/go_web/internal/session/testdb"
)

const fixtureSalt = "$2a$11$abcdefghijklmnopqrstuv"

func newResolver(t *testing.T) (*Resolver, *miniredis.Miniredis, *Codec) {
	t.Helper()
	conn := testdb.Open(t)
	server := miniredis.RunT(t)
	client := redis.NewClient(&redis.Options{Addr: server.Addr()})
	t.Cleanup(func() { client.Close() })
	codec, err := NewCodec("go-web-test-secret-key-base")
	if err != nil {
		t.Fatal(err)
	}
	return &Resolver{Users: &Users{DB: conn}, Redis: client, Codec: codec}, server, codec
}

func signedIn(id int64, salt string, lastSignInAt int64) *Session {
	raw, _ := json.Marshal(map[string]any{
		"warden.user.user.key":     []any{[]any{id}, salt},
		"warden.user.user.session": map[string]any{"last_sign_in_at": lastSignInAt},
	})
	return Parse(raw)
}

func sellerCookie(t *testing.T, _ *Codec, id int64) string {
	t.Helper()
	return sessiontest.Encrypt(t, "go-web-test-secret-key-base", CurrentSellerCookie, []byte(strconv.FormatInt(id, 10)), time.Time{})
}

// User.serialize_from_session(key, _salt) overrides Devise's salt check.
func TestResolveFindsTheSessionUserWhateverTheSalt(t *testing.T) {
	r, _, _ := newResolver(t)
	testdb.User(t, r.Users.DB, 1_500_001, nil)
	ctx := context.Background()

	for _, salt := range []string{fixtureSalt, "stale salt"} {
		auth, err := r.Resolve(ctx, Input{Session: signedIn(1_500_001, salt, 1), Now: time.Now()})
		if err != nil || auth.CurrentUser == nil || auth.CurrentUser.ID != 1_500_001 || auth.CurrentSeller.ID != 1_500_001 {
			t.Fatalf("salt %q: auth = %+v, %v", salt, auth, err)
		}
	}
	for _, s := range []*Session{signedIn(1_999_998, fixtureSalt, 1), nil} {
		auth, err := r.Resolve(ctx, Input{Session: s, Now: time.Now()})
		if err != nil || auth.CurrentUser != nil || auth.CurrentSeller != nil {
			t.Errorf("auth = %+v, %v", auth, err)
		}
	}
}

func TestResolveKeepsTheSellerOnlyForTeamMembers(t *testing.T) {
	r, _, codec := newResolver(t)
	conn := r.Users.DB
	testdb.User(t, conn, 1_500_011, nil)
	testdb.User(t, conn, 1_500_012, nil)
	testdb.User(t, conn, 1_500_013, nil)
	testdb.User(t, conn, 1_500_014, map[string]any{"deleted_at": time.Now()})
	now := time.Now().UTC()
	testdb.Insert(t, conn, "team_memberships", map[string]any{"id": int64(1_500_011), "seller_id": 1_500_012, "user_id": 1_500_011, "role": "admin", "created_at": now, "updated_at": now})
	testdb.Insert(t, conn, "team_memberships", map[string]any{"id": int64(1_500_012), "seller_id": 1_500_013, "user_id": 1_500_011, "role": "admin", "created_at": now, "updated_at": now, "deleted_at": now})
	testdb.Insert(t, conn, "team_memberships", map[string]any{"id": int64(1_500_013), "seller_id": 1_500_014, "user_id": 1_500_011, "role": "admin", "created_at": now, "updated_at": now})

	for seller, want := range map[int64]int64{1_500_012: 1_500_012, 1_500_013: 1_500_011, 1_500_014: 1_500_011} {
		auth, err := r.Resolve(context.Background(), Input{
			Session: signedIn(1_500_011, fixtureSalt, 1), CurrentSellerValue: sellerCookie(t, codec, seller), Now: time.Now(),
		})
		if err != nil {
			t.Fatal(err)
		}
		if auth.CurrentSeller.ID != want || auth.SellerCookieReset != (want != seller) {
			t.Errorf("seller %d: current_seller %d, reset %v", seller, auth.CurrentSeller.ID, auth.SellerCookieReset)
		}
	}

	auth, _ := r.Resolve(context.Background(), Input{Session: nil, CurrentSellerValue: sellerCookie(t, codec, 1_500_012), Now: time.Now()})
	if auth.CurrentSeller != nil || auth.SellerCookieReset {
		t.Error("without a signed-in user there is no current_seller and no cookie reset")
	}
}

func TestResolveImpersonatesOnlyForGumroadTeamMembers(t *testing.T) {
	r, server, _ := newResolver(t)
	conn := r.Users.DB
	testdb.User(t, conn, 1_500_021, map[string]any{"flags": 1 | isTeamMemberFlag})
	testdb.User(t, conn, 1_500_022, nil)
	testdb.User(t, conn, 1_500_023, nil)
	server.Set("impersonated_user_by_admin_1500021", "1500023")
	server.Set("impersonated_user_by_admin_1500022", "1500023")

	auth, err := r.Resolve(context.Background(), Input{Session: signedIn(1_500_021, fixtureSalt, 1), Now: time.Now()})
	if err != nil || !auth.Impersonating() || auth.LoggedInUser().ID != 1_500_023 || auth.ImpersonatingUser().ID != 1_500_021 {
		t.Fatalf("auth = %+v, %v", auth, err)
	}
	if auth.CurrentSeller.ID != 1_500_023 {
		t.Errorf("current_seller resets to logged_in_user, the impersonated user; got %d", auth.CurrentSeller.ID)
	}

	auth, _ = r.Resolve(context.Background(), Input{Session: signedIn(1_500_022, fixtureSalt, 1), Now: time.Now()})
	if auth.Impersonating() {
		t.Error("a non team member's stale key must be ignored")
	}

	actor := &User{ID: 1_500_021, Flags: isTeamMemberFlag}
	auth, _ = r.Resolve(context.Background(), Input{HasToken: true, APIActor: actor, Now: time.Now()})
	if !auth.Impersonating() || auth.CurrentUser != nil {
		t.Errorf("a token's team member impersonates without a session: %+v", auth)
	}
}

func TestResolveFlagsSessionsSignedInBeforeTheInvalidation(t *testing.T) {
	r, _, _ := newResolver(t)
	invalidatedAt := time.Date(2026, 10, 1, 12, 0, 0, 0, time.UTC)
	testdb.User(t, r.Users.DB, 1_500_031, map[string]any{"last_active_sessions_invalidated_at": invalidatedAt})

	for lastSignIn, want := range map[int64]bool{invalidatedAt.Unix() - 1: true, invalidatedAt.Unix(): false, invalidatedAt.Unix() + 60: false} {
		auth, err := r.Resolve(context.Background(), Input{Session: signedIn(1_500_031, fixtureSalt, lastSignIn), Now: time.Now()})
		if err != nil || auth.SessionInvalidated != want {
			t.Errorf("last_sign_in_at %d: invalidated %v, want %v (%v)", lastSignIn, auth.SessionInvalidated, want, err)
			continue
		}
		// sign_out clears current_user; current_seller stays memoized.
		if want && (auth.CurrentUser != nil || auth.Actor != nil || auth.LoggedInUser() != nil || auth.CurrentSeller == nil) {
			t.Errorf("signed out: %+v", auth)
		}
	}
	raw, _ := json.Marshal(map[string]any{"warden.user.user.key": []any{[]any{1_500_031}, fixtureSalt}})
	if auth, _ := r.Resolve(context.Background(), Input{Session: Parse(raw), Now: time.Now()}); !auth.SessionInvalidated {
		t.Error("a session without last_sign_in_at is signed out")
	}
}
