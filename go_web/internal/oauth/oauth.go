// Package oauth is the slice of Doorkeeper 5.7 that doorkeeper_authorize! runs, plus
// ApplicationController#doorkeeper_token's binding rules (MCP resources, brand tokens).
package oauth

import (
	"context"
	"database/sql"
	"errors"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/db"
	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/session"
)

// Token is an oauth_access_tokens row. Gumroad stores tokens in plaintext and has no
// previous_refresh_token column, so lookups never write.
type Token struct {
	ID               int64
	ResourceOwnerID  *int64
	Scopes           string
	ExpiresIn        *int64
	RevokedAt        *time.Time
	CreatedAt        time.Time
	Resource         string
	TeamMembershipID *int64
	// Owner is User.find_by(id: resource_owner_id), read with the token; nil when missing.
	Owner *session.User
	// Member is the admin team member a brand token acts as, which Bound resolves.
	Member *session.User
}

var bearerPrefix = regexp.MustCompile(`(?im)^Bearer `)

// FromRequest is OAuth::Token.from_request with the default access_token_methods: the
// Bearer Authorization header, then the access_token and bearer_token params. The first
// present one wins; when it is an array or hash its #to_s matches no stored token, so ok
// is false without looking further.
func FromRequest(authorization string, param func(name string) any) (string, bool) {
	if bearerPrefix.MatchString(authorization) {
		if token := bearerPrefix.ReplaceAllString(authorization, ""); !rails.Blank(token) {
			return token, true
		}
	}
	for _, name := range []string{"access_token", "bearer_token"} {
		if v := param(name); rails.Present(v) {
			return rails.String(v)
		}
	}
	return "", false
}

func (t *Token) Revoked(now time.Time) bool {
	return t.RevokedAt != nil && !t.RevokedAt.After(now)
}

func (t *Token) Expired(now time.Time) bool {
	return t.ExpiresIn != nil && now.After(t.CreatedAt.Add(time.Duration(*t.ExpiresIn)*time.Second))
}

func (t *Token) Accessible(now time.Time) bool { return !t.Expired(now) && !t.Revoked(now) }

// IncludesScope is includes_scope?: any one of the required scopes is enough.
func (t *Token) IncludesScope(required ...string) bool {
	granted := strings.Fields(t.Scopes)
	for _, scope := range required {
		for _, g := range granted {
			if g == scope {
				return true
			}
		}
	}
	return len(required) == 0
}

type Store struct {
	DB    *sql.DB
	Users *session.Users
}

// ByToken is AccessToken.by_token: an exact find_by, so MySQL's collation decides case.
// The owner comes back in the same statement.
func (s *Store) ByToken(ctx context.Context, token string) (*Token, error) {
	t := &Token{}
	var resource sql.NullString
	var owner session.UserScan
	targets := append([]any{&t.ID, &t.ResourceOwnerID, &t.Scopes, &t.ExpiresIn, db.Time(&t.RevokedAt), &t.CreatedAt, &resource, &t.TeamMembershipID},
		owner.Targets()...)
	err := s.DB.QueryRowContext(ctx, `SELECT t.id, t.resource_owner_id, COALESCE(t.scopes, ''), t.expires_in, t.revoked_at,
		t.created_at, t.resource, t.team_membership_id, `+session.UserColumns("u")+`
		FROM oauth_access_tokens t LEFT JOIN users u ON u.id = t.resource_owner_id
		WHERE t.token = ? LIMIT 1`, token).Scan(targets...)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	t.Resource = resource.String
	t.Owner = owner.User()
	return t, err
}

// Bound is ApplicationController#doorkeeper_token for the token FromRequest found: nil when
// there is none, when it is bound to another MCP resource (resourceIdentifier is
// "#{PROTOCOL}://#{DOMAIN}#{request.path}"), or when it is a brand token whose team member
// can no longer switch in. A brand token comes back with its Member set.
func (s *Store) Bound(ctx context.Context, raw, resourceIdentifier string, now time.Time) (*Token, error) {
	token, err := s.ByToken(ctx, raw)
	if err != nil || token == nil {
		return nil, err
	}
	if strings.TrimSpace(token.Resource) != "" && token.Resource != resourceIdentifier {
		return nil, nil
	}
	if token.TeamMembershipID == nil {
		return token, nil
	}
	if token.Member, err = s.teamMember(ctx, token); err != nil || token.Member == nil || !token.Member.Alive() {
		return nil, err
	}
	if at := token.Member.LastActiveSessionsInvalidatedAt; at != nil && !token.CreatedAt.After(*at) {
		return nil, nil
	}
	return token, nil
}

// teamMember is MobileAccountToken.team_membership_for(token)&.user, in one statement.
func (s *Store) teamMember(ctx context.Context, token *Token) (*session.User, error) {
	if token.ResourceOwnerID == nil {
		return nil, nil
	}
	var member session.UserScan
	err := s.DB.QueryRowContext(ctx, `SELECT `+session.UserColumns("member")+` FROM team_memberships
		INNER JOIN users seller ON seller.id = team_memberships.seller_id
		LEFT JOIN users member ON member.id = team_memberships.user_id
		WHERE team_memberships.role = 'admin' AND team_memberships.deleted_at IS NULL AND seller.deleted_at IS NULL
		AND team_memberships.id = ? AND team_memberships.seller_id = ? LIMIT 1`, *token.TeamMembershipID, *token.ResourceOwnerID).
		Scan(member.Targets()...)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return member.User(), err
}

// ErrOwnerNotFound is CurrentApiUser's User.find raising RecordNotFound, a 404 in Rails.
var ErrOwnerNotFound = errors.New("oauth: token owner not found")

// Actor is Impersonate#current_user_from_api_or_web for a bound token: its team member,
// else its owner.
func (t *Token) Actor() (*session.User, error) {
	if t.Member != nil {
		return t.Member, nil
	}
	if t.Owner == nil {
		return nil, ErrOwnerNotFound
	}
	return t.Owner, nil
}

// Authorize is doorkeeper_authorize!(scopes...) with Doorkeeper's default render options:
// when it returns false it has answered with `head 401` or `head 403` and the error's
// headers ("no-store, no-cache" is what Rails' Cache-Control merge reduces to "no-store").
// Api::Mobile::BaseController's valid_doorkeeper_token? also needs a resource owner, so a
// client-credentials token is answered as an invalid one.
func Authorize(w http.ResponseWriter, req *rails.Request, token *Token, scopes ...string) bool {
	now := req.Now
	ownerless := token != nil && token.ResourceOwnerID == nil
	if token != nil && !ownerless && token.Accessible(now) && token.IncludesScope(scopes...) {
		return true
	}
	w.Header().Set("Cache-Control", "no-store")
	if token != nil && !ownerless && token.Accessible(now) {
		rails.Head(w, req, http.StatusForbidden)
		return false
	}
	description := "The access token is invalid"
	switch {
	case token != nil && token.Revoked(now):
		description = "The access token was revoked"
	case token != nil && token.Expired(now):
		description = "The access token expired"
	}
	w.Header().Set("WWW-Authenticate", `Bearer realm="Doorkeeper", error="invalid_token", error_description="`+description+`"`)
	rails.Head(w, req, http.StatusUnauthorized)
	return false
}
