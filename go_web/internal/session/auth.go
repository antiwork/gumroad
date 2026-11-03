package session

import (
	"context"
	"encoding/json"
	"errors"
	"strconv"
	"time"

	"github.com/redis/go-redis/v9"

	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// CurrentSellerCookie is the encrypted cookie CurrentSeller#switch_seller_account writes.
const CurrentSellerCookie = "current_seller_id"

// Resolver answers logged_in_user, impersonated_user and current_seller for one request.
type Resolver struct {
	Users *Users
	// $redis (REDIS_HOST), which holds Impersonate's keys.
	Redis redis.Cmdable
	Codec *Codec
}

// Input is what the request carries. Session and CurrentSellerValue are empty when
// verify_authenticity_token nulled the session and cookie jar.
type Input struct {
	Session *Session
	// The current_seller_id cookie after Rack unescaped it.
	CurrentSellerValue string
	// APIActor is Impersonate#current_user_from_api_or_web when a Doorkeeper token is
	// present: the token's team member, else its owner. Nil without a token.
	APIActor *User
	HasToken bool
	Now      time.Time
}

// Auth is what the before_actions leave behind.
type Auth struct {
	// CurrentUser is Devise's current_user, from the session.
	CurrentUser      *User
	ImpersonatedUser *User
	// Actor is who impersonates: current_user_from_api_or_web.
	Actor         *User
	CurrentSeller *User
	// SessionInvalidated is invalidate_session_if_necessary signing the session out.
	SessionInvalidated bool
	// SellerCookieReset is reset_current_seller deleting a current_seller_id cookie.
	SellerCookieReset bool
}

func (a *Auth) LoggedInUser() *User {
	if a.ImpersonatedUser != nil {
		return a.ImpersonatedUser
	}
	return a.CurrentUser
}

func (a *Auth) Impersonating() bool { return a.ImpersonatedUser != nil }

// ImpersonatingUser is Impersonate#impersonating_user.
func (a *Auth) ImpersonatingUser() *User {
	if a.Impersonating() {
		return a.Actor
	}
	return nil
}

// Resolve runs, in Rails' order, Warden's session fetch, Impersonate, CurrentSeller's
// verify_current_seller and invalidate_session_if_necessary's check.
func (r *Resolver) Resolve(ctx context.Context, in Input) (*Auth, error) {
	auth := &Auth{}
	var err error
	if auth.CurrentUser, err = r.sessionUser(ctx, in.Session); err != nil {
		return nil, err
	}

	auth.Actor = auth.CurrentUser
	if in.HasToken {
		auth.Actor = in.APIActor
	}
	if auth.Actor != nil && auth.Actor.IsTeamMember() {
		if auth.ImpersonatedUser, err = r.impersonatedUser(ctx, auth.Actor); err != nil {
			return nil, err
		}
	}

	if err := r.resolveCurrentSeller(ctx, auth, in); err != nil {
		return nil, err
	}

	// Checked against logged_in_user, so the impersonated user's invalidation applies.
	if logged := auth.LoggedInUser(); auth.CurrentUser != nil && logged != nil && logged.LastActiveSessionsInvalidatedAt != nil {
		lastSignIn, ok := in.Session.LastSignInAt()
		auth.SessionInvalidated = !ok || lastSignIn < logged.LastActiveSessionsInvalidatedAt.Unix()
	}
	if auth.SessionInvalidated {
		// sign_out clears @current_user and locks Warden; @_impersonated_user and
		// @_current_seller stay memoized, and so does the token's actor.
		auth.CurrentUser = nil
		if !in.HasToken {
			auth.Actor = nil
		}
	}
	return auth, nil
}

// sessionUser is User.serialize_from_session(key, _salt): find_by(id:), salt unchecked.
func (r *Resolver) sessionUser(ctx context.Context, s *Session) (*User, error) {
	id, ok := s.WardenUser()
	if !ok {
		return nil, nil
	}
	return r.Users.Find(ctx, id, false)
}

func (r *Resolver) impersonatedUser(ctx context.Context, actor *User) (*User, error) {
	value, err := r.Redis.Get(ctx, "impersonated_user_by_admin_"+strconv.FormatInt(actor.ID, 10)).Result()
	if errors.Is(err, redis.Nil) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	id, ok := rails.StringToI(value)
	if !ok {
		return nil, nil
	}
	return r.Users.Find(ctx, id, true)
}

// resolveCurrentSeller is CurrentSeller#current_seller followed by verify_current_seller.
func (r *Resolver) resolveCurrentSeller(ctx context.Context, auth *Auth, in Input) error {
	if auth.CurrentUser == nil {
		return nil
	}
	logged := auth.LoggedInUser()
	var seller *User
	if in.CurrentSellerValue != "" {
		if raw, ok := r.Codec.Decrypt(CurrentSellerCookie, in.CurrentSellerValue, in.Now); ok {
			if id, ok := cookieID(raw); ok {
				var known bool
				if seller, known = loaded(id, auth.CurrentUser, logged); !known {
					var err error
					if seller, err = r.Users.Find(ctx, id, true); err != nil {
						return err
					}
				}
			}
		}
	}
	if seller != nil {
		member, err := r.Users.MemberOf(ctx, logged, seller)
		if err != nil {
			return err
		}
		if member {
			auth.CurrentSeller = seller
			return nil
		}
	}
	auth.CurrentSeller = logged
	auth.SellerCookieReset = in.CurrentSellerValue != ""
	return nil
}

// loaded is User.alive.find_by_id for a user this request already read: known reports
// whether one matched, and a deleted one is nil as the alive scope makes it.
func loaded(id int64, users ...*User) (user *User, known bool) {
	for _, u := range users {
		if u != nil && u.ID == id {
			if !u.Alive() {
				return nil, true
			}
			return u, true
		}
	}
	return nil, false
}

// cookieID is what User.alive.find_by_id makes of the cookie's JSON value.
func cookieID(raw []byte) (int64, bool) {
	var v any
	if err := json.Unmarshal(raw, &v); err != nil {
		return 0, false
	}
	switch v := v.(type) {
	case float64:
		return int64(v), v == float64(int64(v))
	case string:
		n, err := strconv.ParseInt(v, 10, 64)
		return n, err == nil
	}
	return 0, false
}
