package viewer

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"slices"
	"strconv"
	"strings"

	"github.com/antiwork/gumroad/go_web/internal/compliance"
	"github.com/antiwork/gumroad/go_web/internal/pages"
	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/session"
	"github.com/antiwork/gumroad/go_web/internal/web"
)

// promotableNavItems is DashboardNav::PROMOTABLE_ITEMS.
var promotableNavItems = []string{"profile", "pages", "collaborators", "checkout", "emails", "workflows", "analytics",
	"affiliates", "community", "library"}

// share builds the signed-in share: logged_in_user, current_seller, current_user and
// prompt_passkey_setup. Whatever goes to Rails is read first.
func (l *Loader) share(ctx context.Context, req *rails.Request, s *session.Session, v *Viewer) error {
	u, seller := v.User, v.Seller
	if _, ok := timeZoneMapping[seller.Timezone.String]; !ok {
		return pages.Fallback("time zone")
	}
	var err error
	var sells, published, bought, passkeys, ownCommunity, purchasedCommunity bool
	const chatEnabled = "communities.deleted_at IS NULL AND links.purchase_disabled_at IS NULL AND links.banned_at IS NULL" +
		" AND links.deleted_at IS NULL AND (links.flags & 536870912 = 536870912)"
	const communities = " FROM communities INNER JOIN links ON communities.resource_type = 'Link' AND communities.resource_id = links.id"
	const purchased = communities + " INNER JOIN purchases ON purchases.link_id = links.id WHERE " + chatEnabled +
		" AND purchases.purchase_state = 'successful'"
	// One round trip; each EXISTS stops at its first row.
	if err := l.DB.QueryRowContext(ctx, "SELECT EXISTS(SELECT 1 FROM links WHERE links.user_id = ?),"+
		" EXISTS(SELECT 1 FROM links WHERE links.user_id = ? AND links.purchase_disabled_at IS NULL AND links.banned_at IS NULL AND links.deleted_at IS NULL),"+
		" EXISTS(SELECT 1 FROM purchases WHERE purchases.purchaser_id = ? AND purchases.purchase_state = 'successful'),"+
		" EXISTS(SELECT 1 FROM webauthn_credentials WHERE webauthn_credentials.user_id = ?),"+
		" EXISTS(SELECT 1"+communities+" WHERE communities.seller_id = ? AND "+chatEnabled+"),"+
		" EXISTS(SELECT 1"+purchased+" AND purchases.purchaser_id = ?)", seller.ID, seller.ID, seller.ID, u.ID, u.ID, u.ID).
		Scan(&sells, &published, &bought, &passkeys, &ownCommunity, &purchasedCommunity); err != nil {
		return err
	}
	// has_accessible_communities?: then a guest purchase under the visitor's email.
	community := ownCommunity || purchasedCommunity
	if !community && u.Email.Valid {
		if community, err = l.exists(ctx, "SELECT 1 AS one"+purchased+" AND purchases.email = ?"+
			" AND (purchases.purchaser_id IS NULL OR purchases.purchaser_id != ?) LIMIT 1", u.Email.String, u.ID); err != nil {
			return err
		}
	}
	// logged_in_user's payout keys read the visitor's compliance info and bank account,
	// current_seller's props the seller's.
	users := []*User{u}
	if seller != u {
		users = append(users, seller)
	}
	for _, x := range users {
		if x.info, err = compliance.Load(ctx, l.DB, x.ID); err != nil {
			return err
		}
		if x.bank, err = l.activeBankAccountType(ctx, x.ID); err != nil {
			return err
		}
	}
	if v.LoggedInUser, err = l.loggedInUserProps(ctx, req, v, community); err != nil {
		return err
	}
	if v.CurrentSeller, err = l.currentSellerProps(ctx, req, seller, sells, published, bought); err != nil {
		return err
	}
	v.CurrentUser = rails.NewRHash().Sym("name", u.displayName(false)).Sym("avatar_url", u.AvatarURL).Sym("impersonated_user", nil)
	// show_passkey_setup_prompt?: the visitor's own account, not the mobile app, and the sign-in
	// asked for it.
	if c, ok := req.Cookie("is_gumroad_mobile_app"); seller == u && (!ok || rails.Blank(c)) {
		match, err := sessionInt(s.Get("prompt_passkey_setup"), u.ID)
		if err != nil {
			return err
		}
		v.PromptPasskeySetup = match && !passkeys
	}
	return nil
}

// loggedInUserProps is RenderingExtension#logged_in_user_props: the visitor's own keys, and the
// policies their role on the current seller allows.
func (l *Loader) loggedInUserProps(ctx context.Context, req *rails.Request, v *Viewer, community bool) (*rails.RHash, error) {
	u := v.User
	memberships, err := l.teamMembershipsProps(ctx, req, v)
	if err != nil {
		return nil, err
	}
	confirmed := u.ConfirmedAt.Valid
	brand := false
	if confirmed {
		if brand, err = l.flag(ctx, "brand_accounts", u.ID); err != nil {
			return nil, err
		}
	}
	legal, err := u.info.LegalEntityCountryCode()
	if err != nil {
		return nil, err
	}
	// CreateBrandAccountService: NEW_ACCOUNT_CREATION_BLOCKED_COUNTRIES is IN alone, and only an
	// IndianBankAccount's country is IN.
	copied := legal != "" && legal != "IN" && u.bank != "" && u.bank != "CardBankAccount" && u.bank != "IndianBankAccount"
	navItems, err := l.promotedNavItems(ctx, u.ID)
	if err != nil {
		return nil, err
	}
	lazyImages, err := l.flag(ctx, "lazy_load_offscreen_discover_images", u.ID)
	if err != nil {
		return nil, err
	}
	// Each action's policy method, as the roles it lets in besides the owner.
	allowed := func(keys []string, roles ...string) *rails.RHash {
		r := rails.NewRHash()
		for _, k := range keys {
			r.Sym(k, v.HasRole(roles...))
		}
		return r
	}
	all := []string{RoleAccountant, RoleAdmin, RoleMarketing, RoleSupport}
	write := []string{RoleAdmin, RoleMarketing}
	policies := rails.NewRHash().
		Sym("affiliate_requests_onboarding_form", allowed([]string{"update"}, write...)).
		Sym("direct_affiliate", allowed([]string{"create", "update"}, write...)).
		Sym("collaborator", allowed([]string{"create", "update"}, RoleAdmin)).
		Sym("product", allowed([]string{"create"}, write...)).
		Sym("product_review_response", allowed([]string{"update"}, RoleAdmin, RoleSupport)).
		Sym("balance", allowed([]string{"index", "export"}, RoleAccountant, RoleAdmin, RoleSupport)).
		Sym("checkout_offer_code", allowed([]string{"create"}, write...)).
		Sym("checkout_form", allowed([]string{"update"}, write...)).
		Sym("upsell", allowed([]string{"create"}, write...)).
		Sym("settings_payments_user", allowed([]string{"show"}, RoleAdmin)).
		Sym("settings_main_user", allowed([]string{"update_username"})).
		Sym("settings_profile", rails.NewRHash().Sym("manage_social_connections", v.HasRole()).Sym("update", v.HasRole(write...))).
		Sym("settings_third_party_analytics_user", allowed([]string{"update"}, RoleAdmin)).
		Sym("installment", allowed([]string{"create"}, write...)).
		Sym("workflow", allowed([]string{"create"}, write...)).
		Sym("utm_link", allowed([]string{"index"}, all...)).
		Sym("community", rails.NewRHash().Sym("index", community)).
		Sym("churn", allowed([]string{"show"}, all...)).
		Sym("page", rails.NewRHash().Sym("index", v.HasRole(all...)).Sym("create", v.HasRole(write...)))
	return rails.NewRHash().
		Sym("id", nullString(u.ExternalID)).
		Sym("email", nullString(u.Email)).
		Sym("name", nullString(u.Name)).
		Sym("avatar_url", u.AvatarURL).
		Sym("confirmed", confirmed).
		Sym("team_memberships", memberships).
		Sym("can_create_brand_account", confirmed && brand).
		Sym("has_payout_setup_to_port", rails.Present(u.PayAddr.String) || copied).
		Sym("can_port_bank_payout_setup", legal != "IN").
		Sym("will_copy_bank_payout", copied).
		Sym("policies", policies).
		Sym("promoted_nav_items", navItems).
		Sym("lazy_load_offscreen_discover_images", lazyImages), nil
}

// teamMembershipsProps is UserMembershipsPresenter#props over the visitor's memberships.
func (l *Loader) teamMembershipsProps(ctx context.Context, req *rails.Request, v *Viewer) ([]any, error) {
	u := v.User
	list := u.memberships
	out := []any{}
	if len(list) == 0 {
		return out, nil
	}
	if !slices.ContainsFunc(list, func(m *membership) bool { return m.role.String == RoleOwner }) {
		// Rails notifies about the missing owner row and renders none.
		web.Logger(req.HTTP).Warn("missing owner team membership", "user_id", u.ID)
		return out, nil
	}
	sellers := map[int64]*User{u.ID: u, v.Seller.ID: v.Seller}
	var others []any
	for _, m := range list {
		if _, ok := sellers[m.sellerID]; !ok && !slices.Contains(others, any(m.sellerID)) {
			others = append(others, m.sellerID)
		}
	}
	if len(others) > 0 {
		rows, err := l.DB.QueryContext(ctx, "SELECT users.id, users.name, users.username, users.external_id, users.email,"+
			" users.unconfirmed_email FROM users WHERE users.id IN (?"+strings.Repeat(", ?", len(others)-1)+")", others...)
		if err != nil {
			return nil, err
		}
		defer rows.Close()
		var loaded []*User
		for rows.Next() {
			s := &User{}
			if err := rows.Scan(&s.ID, &s.Name, &s.Username, &s.ExternalID, &s.Email, &s.UnconfirmedEmail); err != nil {
				return nil, err
			}
			loaded = append(loaded, s)
		}
		if err := rows.Err(); err != nil {
			return nil, err
		}
		rows.Close()
		for _, s := range loaded {
			if s.AvatarURL, err = l.avatarURL(ctx, v, s.ID); err != nil {
				return nil, err
			}
			sellers[s.ID] = s
		}
	}
	for _, m := range list {
		seller := sellers[m.sellerID]
		if seller == nil {
			// Gone since the join found it.
			return nil, pages.Fallback("team membership seller")
		}
		out = append(out, rails.NewRHash().
			Sym("id", l.IDs.Encrypt(m.id)).
			Sym("seller_name", seller.displayName(true)).
			Sym("seller_avatar_url", seller.AvatarURL).
			Sym("has_some_read_only_access", m.role.String != RoleOwner && m.role.String != RoleAdmin).
			Sym("is_selected", m.sellerID == v.Seller.ID))
	}
	return out, nil
}

// promotedNavItems is User#promoted_nav_item_keys. The pluck has no ORDER BY, so the statement
// is Rails' own, for MySQL to take the same plan.
func (l *Loader) promotedNavItems(ctx context.Context, userID int64) ([]any, error) {
	rows, err := l.DB.QueryContext(ctx, "SELECT `dashboard_nav_promotions`.`nav_item` FROM `dashboard_nav_promotions`"+
		" WHERE `dashboard_nav_promotions`.`user_id` = ?", userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []any{}
	for rows.Next() {
		var item sql.NullString
		if err := rows.Scan(&item); err != nil {
			return nil, err
		}
		if slices.Contains(promotableNavItems, item.String) && !slices.Contains(out, any(item.String)) {
			out = append(out, item.String)
		}
	}
	return out, rows.Err()
}

// sessionInt is session value == id: a JSON Integer, or a Float equal to it, which Ruby's ==
// would also accept and this port leaves to Rails.
func sessionInt(v any, id int64) (bool, error) {
	n, ok := v.(json.Number)
	if !ok {
		return false, nil
	}
	if strings.ContainsAny(string(n), ".eE") {
		return false, pages.Fallback("passkey prompt session")
	}
	return string(n) == strconv.FormatInt(id, 10), nil
}

// currentSellerProps is UserPresenter#as_current_seller for the current seller, u.
func (l *Loader) currentSellerProps(ctx context.Context, req *rails.Request, u *User, sells, published, bought bool) (*rails.RHash, error) {
	zone, offset, err := railsTimeZone(u.Timezone.String, req.Now)
	if err != nil {
		return nil, err
	}
	canPublish, err := l.canPublishProducts(ctx, u)
	if err != nil {
		return nil, err
	}
	var blocked any
	if !canPublish {
		if blocked, err = l.publishBlockedReason(ctx, u.ID); err != nil {
			return nil, err
		}
	}
	var subdomain any
	if rails.Present(u.username()) {
		// User#subdomain: the username with dashes for underscores, under ROOT_DOMAIN.
		subdomain = strings.ReplaceAll(u.username(), "_", "-") + "." + l.RootDomain
	}
	noRail, err := noPayoutRail(u.bank, u.info)
	if err != nil {
		return nil, err
	}
	met, unsupported := true, false
	if u.info != nil {
		if unsupported, err = guardianUnsupported(u.info, req.Now); err != nil {
			return nil, err
		}
		if met, err = l.guardianRequirementMet(ctx, u.info, req.Now); err != nil {
			return nil, err
		}
	}
	// User#seller_profile's colors and font, all NULL for the profile it builds when there's no row.
	var background, highlight, font sql.NullString
	err = l.DB.QueryRowContext(ctx, "SELECT highlight_color, background_color, font FROM seller_profiles WHERE seller_id = ? LIMIT 1",
		u.ID).Scan(&highlight, &background, &font)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}
	or := func(s sql.NullString, def string) string {
		if !s.Valid {
			return def
		}
		return s.String
	}
	return rails.NewRHash().
		Sym("id", nullString(u.ExternalID)).
		Sym("email", nullString(u.Email)).
		Sym("name", u.displayName(true)).
		Sym("subdomain", subdomain).
		Sym("avatar_url", u.AvatarURL).
		Sym("is_buyer", !sells && bought).
		Sym("time_zone", rails.NewRHash().Sym("name", zone).Sym("offset", int64(offset))).
		Sym("has_published_products", published).
		Sym("can_publish_products", canPublish).
		Sym("publish_blocked_reason", blocked).
		Sym("no_payout_rail_in_compliance_country", noRail).
		Sym("legal_guardian_requirement_met", met).
		Sym("legal_guardian_unsupported", unsupported).
		Sym("is_name_invalid_for_email_delivery", rails.Present(u.Name.String) && strings.Contains(u.Name.String, ":")).
		Sym("profile_background_color", or(background, "#ffffff")).
		Sym("profile_highlight_color", or(highlight, "#ff90e8")).
		Sym("profile_font", or(font, "ABC Favorit")), nil
}

func nullString(s sql.NullString) any {
	if !s.Valid {
		return nil
	}
	return s.String
}
