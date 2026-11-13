// Package viewer is the signed-in visitor of a full page: their users row, the seller they act
// as, and InertiaRendering's signed-in share (logged_in_user, current_seller, current_user and
// prompt_passkey_setup), which every page renders the same way.
package viewer

import (
	"context"
	"database/sql"
	"errors"
	"slices"
	"strconv"

	"github.com/antiwork/gumroad/go_web/internal/compliance"
	"github.com/antiwork/gumroad/go_web/internal/db"
	"github.com/antiwork/gumroad/go_web/internal/flipper"
	"github.com/antiwork/gumroad/go_web/internal/obfuscate"
	"github.com/antiwork/gumroad/go_web/internal/pages"
	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/session"
	"github.com/antiwork/gumroad/go_web/internal/storage"
)

// TeamMembership::ROLES.
const (
	RoleOwner      = "owner"
	RoleAccountant = "accountant"
	RoleAdmin      = "admin"
	RoleMarketing  = "marketing"
	RoleSupport    = "support"
)

// User is a signed-in user's users row, as the share and the pages read it.
type User struct {
	ID                                                  int64
	Name, Username, ExternalID, Email, UnconfirmedEmail sql.NullString
	PayAddr, Timezone, CurrencyType, KindleEmail        sql.NullString
	ConfirmedAt                                         db.NullTime
	AvatarURL                                           string

	info *compliance.Info
	// bank is active_bank_account's STI type, "" without one.
	bank string
	// memberships are the visitor's own, which the role and team_memberships read.
	memberships []*membership
}

// Viewer is the signed-in visitor, the seller they view the page as, and the signed-in share's
// props in the order the share block sets them.
type Viewer struct {
	User, Seller *User
	// Role is the visitor's team role on Seller, "" on their own account.
	Role                                     string
	LoggedInUser, CurrentSeller, CurrentUser *rails.RHash
	PromptPasskeySetup                       bool
	// AvatarResizes are the users whose avatar_url served the upload unresized, each enqueueing
	// GenerateAvatarVariantJob, in the order Rails reads them.
	AvatarResizes []int64
}

// HasRole is a role_*_for?(current_seller) check: the visitor's own account always passes,
// another's when their membership's role is one of roles.
func (v *Viewer) HasRole(roles ...string) bool {
	return v.Seller == v.User || slices.Contains(roles, v.Role)
}

// Loader reads the signed-in visitor and builds the share.
type Loader struct {
	DB      *sql.DB
	IDs     *obfuscate.IDs
	Avatars *storage.Avatars
	// Flag is a Flipper flag by name.
	Flag func(name string) *flipper.Flag
	// RootDomain is ROOT_DOMAIN, for current_seller's subdomain.
	RootDomain string
	// GumroadAdminID is GUMROAD_ADMIN_ID, who writes payout setup notes; 0 leaves a page that
	// reads them to Rails.
	GumroadAdminID int64
}

// Load is the signed-in visitor, nil when no one is signed in. Prepare has sent staff, and with
// them impersonation, to Rails.
func (l *Loader) Load(ctx context.Context, req *rails.Request, s *session.Session, auth *session.Auth) (*Viewer, error) {
	logged := auth.LoggedInUser()
	switch {
	case logged == nil:
		return nil, nil
	case auth.CurrentSeller == nil:
		// Only without a Devise session, which signs no one in here.
		return nil, pages.Fallback("no current seller")
	}
	v := &Viewer{}
	u, err := l.loadUser(ctx, v, logged.ID)
	if err != nil {
		return nil, err
	}
	if u.memberships, err = l.loadMemberships(ctx, u.ID); err != nil {
		return nil, err
	}
	seller := u
	if auth.CurrentSeller.ID != u.ID {
		if auth.CurrentSeller.IsTeamMember() {
			// can_publish_products? starts with is_team_member?.
			return nil, pages.Fallback("staff current seller")
		}
		if seller, err = l.loadUser(ctx, v, auth.CurrentSeller.ID); err != nil {
			return nil, err
		}
		// find_user_membership_for_seller!: the first of the same list team_memberships renders.
		i := slices.IndexFunc(u.memberships, func(m *membership) bool { return m.sellerID == seller.ID })
		if i < 0 {
			return nil, pages.Fallback("team membership")
		}
		v.Role = u.memberships[i].role.String
	}
	v.User, v.Seller = u, seller
	if err := l.share(ctx, req, s, v); err != nil {
		return nil, err
	}
	return v, nil
}

func (l *Loader) loadUser(ctx context.Context, v *Viewer, id int64) (*User, error) {
	u := &User{}
	if err := l.DB.QueryRowContext(ctx, "SELECT users.id, users.name, users.username, users.external_id, users.email,"+
		" users.unconfirmed_email, users.payment_address, users.timezone, users.currency_type, users.kindle_email, users.confirmed_at"+
		" FROM users WHERE users.id = ? LIMIT 1", id).Scan(&u.ID, &u.Name, &u.Username, &u.ExternalID, &u.Email, &u.UnconfirmedEmail,
		&u.PayAddr, &u.Timezone, &u.CurrencyType, &u.KindleEmail, &u.ConfirmedAt); err != nil {
		return nil, err
	}
	var err error
	u.AvatarURL, err = l.avatarURL(ctx, v, id)
	return u, err
}

// avatarURL is User#avatar_url, noting the GenerateAvatarVariantJob it enqueues for an avatar it
// serves unresized.
func (l *Loader) avatarURL(ctx context.Context, v *Viewer, userID int64) (string, error) {
	avatar, resize, err := l.Avatars.URL(ctx, userID)
	if errors.Is(err, storage.ErrUnported) {
		return "", pages.Fallback("avatar")
	}
	if err != nil {
		return "", err
	}
	if resize && !slices.Contains(v.AvatarResizes, userID) {
		v.AvatarResizes = append(v.AvatarResizes, userID)
	}
	return avatar, nil
}

// username is User#username: the column, else the external id.
func (u *User) username() string {
	if rails.Present(u.Username.String) {
		return u.Username.String
	}
	return u.ExternalID.String
}

// displayName is User#display_name.
func (u *User) displayName(preferEmail bool) any {
	if rails.Present(u.Name.String) {
		return u.Name.String
	}
	formEmail := func() any {
		if rails.Present(u.UnconfirmedEmail.String) {
			return u.UnconfirmedEmail.String
		}
		if rails.Present(u.Email.String) {
			return u.Email.String
		}
		return nil
	}
	username := u.username()
	if preferEmail && username == u.ExternalID.String {
		if e := formEmail(); e != nil {
			return e
		}
		if rails.Present(username) {
			return username
		}
		return nil
	}
	if rails.Present(username) {
		return username
	}
	return formEmail()
}

// membership is one of user_memberships_not_deleted_and_ordered.
type membership struct {
	id, sellerID int64
	role         sql.NullString
}

// loadMemberships is user_memberships_not_deleted_and_ordered, in Rails' own statement: rows tied
// on both sort columns come back in whatever order MySQL's plan for it gives.
func (l *Loader) loadMemberships(ctx context.Context, userID int64) ([]*membership, error) {
	var list []*membership
	err := db.ScanNamed(ctx, l.DB, func(cols map[string]any) func() {
		m := &membership{}
		cols["id"], cols["seller_id"], cols["role"] = &m.id, &m.sellerID, &m.role
		return func() { list = append(list, m) }
	}, "SELECT `team_memberships`.* FROM `team_memberships` INNER JOIN `users` ON `users`.`id` = `team_memberships`.`seller_id`"+
		" WHERE `team_memberships`.`user_id` = ? AND `team_memberships`.`deleted_at` IS NULL AND `users`.`deleted_at` IS NULL"+
		" ORDER BY `team_memberships`.`last_accessed_at` DESC, `team_memberships`.`created_at` DESC", userID)
	return list, err
}

// flag is Feature.active?(name, user); a flag only Flipper can evaluate goes to Rails.
func (l *Loader) flag(ctx context.Context, name string, userID int64) (bool, error) {
	on, err := l.Flag(name).ActiveFor(ctx, "User;"+strconv.FormatInt(userID, 10))
	if errors.Is(err, flipper.ErrUnevaluable) {
		return false, pages.Fallback("flag " + name)
	}
	return on, err
}

func (l *Loader) exists(ctx context.Context, query string, args ...any) (bool, error) {
	var one int
	err := l.DB.QueryRowContext(ctx, query, args...).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}
