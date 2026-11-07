package products

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/db"
	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/web"
)

// guardianRequiredBelowAge is UserComplianceInfo::GUARDIAN_REQUIRED_BELOW_AGE.
const guardianRequiredBelowAge = 18

var (
	// promotableNavItems is DashboardNav::PROMOTABLE_ITEMS.
	promotableNavItems = []string{"profile", "pages", "collaborators", "checkout", "emails", "workflows", "analytics",
		"affiliates", "community", "library"}
	// nativePayoutCountries is User::Compliance::SUPPORTED_COUNTRIES' alpha2 codes.
	nativePayoutCountries = strings.Fields(`US CA AU GB HK NZ SG CH PL CZ TH BG DK HU KR AE IL TT PH TZ NA AG RO SE MX AR PE NO AL BH JO
		NG AZ IN AO NE SM VN ET BN GY GT TW ID CR BW CL PK TR BA MA RS ZA KE EG CO RW SA JP BD BT LA MZ KZ EC MY UY MU JM LI DO UZ BO MD
		MK PA SV GI OM TN MG PY GH AM LK KW IS QA BS LC SN KH MN GA DZ MO BJ CI GM AT BE HR CY EE FI FR DE GR IE IT LV LT LU MT MC NL PT
		SK SI ES`)
	// paypalPayoutCountries is PaypalPayoutProcessor::PAYOUT_RECEIVING_COUNTRY_CODES.
	paypalPayoutCountries = strings.Fields(`AD AE AR AT AU BE BG BH BM BR BS BW CA CH CL CN CO CR CY CZ DE DK DO EC EE ES FI FO FR GB
		GE GI GL GR GT HK HN HR HU ID IE IL IN IT JM JO JP KE KW KY KZ LI LS LT LU LV MA MC MD MT MU MX MY MZ NI NL NO NZ OM PA PE PH PL
		PT QA RE RO RS SA SE SG SI SK SM SN SV TR TW US UY VE VN ZA`)
	// usOutlyingAreas is Compliance::Countries::US_OUTLYING_AREA_ALPHA2.
	usOutlyingAreas = []string{"AS", "GU", "MP", "PR", "UM", "VI"}
	// guardianStateCountries is StripeBeneficialOwnersManager::COUNTRIES_WITH_STATE_LIST.
	guardianStateCountries = []string{"US", "CA", "AU", "MX", "AE", "IE", "BR", "JP"}
)

// signedInUser is the signed-in visitor: their users row, and what the page reads of them once.
type signedInUser struct {
	user
	email, unconfirmedEmail, payAddr, timezone, currencyType sql.NullString
	confirmedAt                                              db.NullTime
	avatarURL                                                string

	info *complianceInfo
	// bank is active_bank_account's STI type, "" without one.
	bank      string
	wishlists []*viewerWishlist
	// memberships are the visitor's own, which the role and team_memberships read.
	memberships []*teamMembership
	// The signed-in share's props, in the order the page sets them.
	loggedIn, currentSeller, currentUser *rails.RHash
	promptPasskey                        bool
}

func (h *handler) loadSignedInUser(p *page, id int64) (*signedInUser, error) {
	ctx := p.Ctx
	u := &signedInUser{}
	dest := append(u.user.dest(), &u.email, &u.unconfirmedEmail, &u.payAddr, &u.timezone, &u.currencyType, &u.confirmedAt)
	if err := h.c.DB.QueryRowContext(ctx, "SELECT "+userColumns+", users.email, users.unconfirmed_email, users.payment_address,"+
		" users.timezone, users.currency_type, users.confirmed_at FROM users WHERE users.id = ? LIMIT 1", id).Scan(dest...); err != nil {
		return nil, err
	}
	var err error
	u.avatarURL, err = h.avatarURL(p, id)
	return u, err
}

// displayName is User#display_name.
func (u *signedInUser) displayName(preferEmail bool) any {
	if rails.Present(u.name.String) {
		return u.name.String
	}
	formEmail := func() any {
		if rails.Present(u.unconfirmedEmail.String) {
			return u.unconfirmedEmail.String
		}
		return presence(u.email.String)
	}
	username := sellerUsername(&u.user)
	if preferEmail && username == u.externalID.String {
		if e := formEmail(); e != nil {
			return e
		}
		return presence(username)
	}
	if rails.Present(username) {
		return username
	}
	return formEmail()
}

// loadViewer loads the signed-in visitor, the seller they view the product as, and the
// signed-in share's props. Prepare has sent staff, and with them impersonation, to Rails.
func (h *handler) loadViewer(p *page, prod *product) error {
	logged := p.Auth.LoggedInUser()
	switch {
	case logged == nil:
		return nil
	case p.Auth.CurrentSeller == nil:
		// Only without a Devise session, which signs no one in here.
		return fallback("no current seller")
	}
	// The page's first avatar reads are these.
	defer func() { p.viewerPushes, p.avatarPushes = p.avatarPushes, nil }()
	u, err := h.loadSignedInUser(p, logged.ID)
	if err != nil {
		return err
	}
	if u.memberships, err = h.loadMemberships(p.Ctx, u.id); err != nil {
		return err
	}
	seller := u
	if p.Auth.CurrentSeller.ID != u.id {
		if p.Auth.CurrentSeller.IsTeamMember() {
			// can_publish_products? starts with is_team_member?.
			return fallback("staff current seller")
		}
		if seller, err = h.loadSignedInUser(p, p.Auth.CurrentSeller.ID); err != nil {
			return err
		}
		// find_user_membership_for_seller!: the first of the same list team_memberships renders.
		i := slices.IndexFunc(u.memberships, func(m *teamMembership) bool { return m.sellerID == seller.id })
		if i < 0 {
			return fallback("team membership")
		}
		p.teamRole = u.memberships[i].role.String
	}
	p.viewer, p.currentSeller = u, seller
	if err := h.signedInProps(p); err != nil {
		return err
	}
	if seller.wishlists, err = h.loadViewerWishlists(p.Ctx, seller.id); err != nil {
		return err
	}
	return h.viewerCollaborates(p, prod)
}

// teamMembership is one of user_memberships_not_deleted_and_ordered.
type teamMembership struct {
	id, sellerID int64
	role         sql.NullString
}

// loadMemberships is user_memberships_not_deleted_and_ordered, in Rails' own statement: rows tied
// on both sort columns come back in whatever order MySQL's plan for it gives.
func (h *handler) loadMemberships(ctx context.Context, userID int64) ([]*teamMembership, error) {
	var list []*teamMembership
	err := scanNamed(ctx, h.c.DB, func(cols map[string]any) func() {
		m := &teamMembership{}
		cols["id"], cols["seller_id"], cols["role"] = &m.id, &m.sellerID, &m.role
		return func() { list = append(list, m) }
	}, "SELECT `team_memberships`.* FROM `team_memberships` INNER JOIN `users` ON `users`.`id` = `team_memberships`.`seller_id`"+
		" WHERE `team_memberships`.`user_id` = ? AND `team_memberships`.`deleted_at` IS NULL AND `users`.`deleted_at` IS NULL"+
		" ORDER BY `team_memberships`.`last_accessed_at` DESC, `team_memberships`.`created_at` DESC", userID)
	return list, err
}

// collaboratorFor is User#collaborator_for?.
func (h *handler) collaboratorFor(ctx context.Context, userID, productID int64) (bool, error) {
	return h.exists(ctx, "SELECT 1 FROM links INNER JOIN affiliates_links ON links.id = affiliates_links.link_id"+
		" INNER JOIN affiliates ON affiliates_links.affiliate_id = affiliates.id"+
		" LEFT OUTER JOIN collaborator_invitations ON collaborator_invitations.collaborator_id = affiliates.id"+
		" WHERE affiliates.type = 'Collaborator' AND affiliates.affiliate_user_id = ? AND collaborator_invitations.id IS NULL"+
		" AND affiliates.deleted_at IS NULL AND links.id = ? LIMIT 1", userID, productID)
}

// viewerCollaborates sets p.collaborates for the page's product. It reads unportedShape's
// hasCollaborator gate, so it must run after it, or it finds no collaborator.
func (h *handler) viewerCollaborates(p *page, prod *product) error {
	if p.viewer == nil || !p.hasCollaborator {
		return nil
	}
	var err error
	p.collaborates, err = h.collaboratorFor(p.Ctx, p.viewer.id, prod.id)
	return err
}

// viewerCurrency is ProfileSectionsPresenter's currency_code: the visitor's currency_type.
func viewerCurrency(p *page) any {
	if p.viewer != nil && p.viewer.currencyType.Valid {
		return p.viewer.currencyType.String
	}
	return "usd"
}

// viewerWishlist is one of the current seller's alive wishlists and its alive items.
type viewerWishlist struct {
	id    int64
	name  sql.NullString
	items []wishlistItem
}

type wishlistItem struct {
	productID         int64
	variant, quantity sql.NullInt64
	recurrence        sql.NullString
	rent              sql.NullBool
}

// loadViewerWishlists is seller.wishlists.alive.includes(:alive_wishlist_products), in Rails' own
// statements: neither sets an order, so the plan MySQL picks for them decides it.
func (h *handler) loadViewerWishlists(ctx context.Context, userID int64) ([]*viewerWishlist, error) {
	var lists []*viewerWishlist
	err := scanNamed(ctx, h.c.DB, func(cols map[string]any) func() {
		w := &viewerWishlist{}
		cols["id"], cols["name"] = &w.id, &w.name
		return func() { lists = append(lists, w) }
	}, "SELECT `wishlists`.* FROM `wishlists` WHERE `wishlists`.`user_id` = ? AND `wishlists`.`deleted_at` IS NULL", userID)
	if err != nil || len(lists) == 0 {
		return lists, err
	}
	byID := map[int64]*viewerWishlist{}
	ids := make([]int64, len(lists))
	for i, w := range lists {
		byID[w.id], ids[i] = w, w.id
	}
	err = scanNamed(ctx, h.c.DB, func(cols map[string]any) func() {
		var wishlistID int64
		var item wishlistItem
		cols["wishlist_id"], cols["product_id"], cols["variant_id"] = &wishlistID, &item.productID, &item.variant
		cols["recurrence"], cols["rent"], cols["quantity"] = &item.recurrence, &item.rent, &item.quantity
		return func() { byID[wishlistID].items = append(byID[wishlistID].items, item) }
	}, "SELECT `wishlist_products`.* FROM `wishlist_products` WHERE `wishlist_products`.`deleted_at` IS NULL"+
		" AND `wishlist_products`.`wishlist_id` IN ("+placeholders(len(ids))+")", int64Args(ids)...)
	return lists, err
}

// scanNamed runs a SELECT * and scans each row's columns that bind names into its pointers,
// skipping the rest, then calls what bind returned.
func scanNamed(ctx context.Context, conn *sql.DB, bind func(cols map[string]any) func(), query string, args ...any) error {
	rows, err := conn.QueryContext(ctx, query, args...)
	if err != nil {
		return err
	}
	defer rows.Close()
	names, err := rows.Columns()
	if err != nil {
		return err
	}
	for rows.Next() {
		cols := map[string]any{}
		after := bind(cols)
		dest := make([]any, len(names))
		for i, n := range names {
			if d, ok := cols[n]; ok {
				dest[i] = d
			} else {
				dest[i] = new(sql.RawBytes)
			}
		}
		if err := rows.Scan(dest...); err != nil {
			return err
		}
		after()
	}
	return rows.Err()
}

// viewerWishlists is product_props' wishlists: each of pundit_user.seller's wishlists, with what it
// holds of the product.
func (h *handler) viewerWishlists(p *page, prod *product) []any {
	out := []any{}
	if p.currentSeller == nil {
		return out
	}
	for _, w := range p.currentSeller.wishlists {
		selections := []any{}
		for _, it := range w.items {
			if it.productID != prod.id {
				continue
			}
			var variantID, rent any
			if it.variant.Valid {
				variantID = h.c.IDs.Encrypt(it.variant.Int64)
			}
			if it.rent.Valid {
				rent = it.rent.Bool
			}
			selections = append(selections, rails.NewRHash().Sym("variant_id", variantID).Sym("recurrence", nullString(it.recurrence)).
				Sym("rent", rent).Sym("quantity", nullInt(it.quantity)))
		}
		out = append(out, rails.NewRHash().Sym("id", h.c.IDs.Encrypt(w.id)).Sym("name", nullString(w.name)).
			Sym("selections_in_wishlist", selections))
	}
	return out
}

// signedInProps builds the signed-in share: logged_in_user, current_seller, current_user and
// prompt_passkey_setup. Whatever goes to Rails is read first.
func (h *handler) signedInProps(p *page) error {
	ctx := p.Ctx
	u, seller := p.viewer, p.currentSeller
	if _, ok := timeZoneMapping[seller.timezone.String]; !ok {
		return fallback("time zone")
	}
	var err error
	var sells, published, bought, passkeys, ownCommunity, purchasedCommunity bool
	const chatEnabled = "communities.deleted_at IS NULL AND links.purchase_disabled_at IS NULL AND links.banned_at IS NULL" +
		" AND links.deleted_at IS NULL AND (links.flags & 536870912 = 536870912)"
	const communities = " FROM communities INNER JOIN links ON communities.resource_type = 'Link' AND communities.resource_id = links.id"
	const purchased = communities + " INNER JOIN purchases ON purchases.link_id = links.id WHERE " + chatEnabled +
		" AND purchases.purchase_state = 'successful'"
	// One round trip; each EXISTS stops at its first row.
	if err := h.c.DB.QueryRowContext(ctx, "SELECT EXISTS(SELECT 1 FROM links WHERE links.user_id = ?),"+
		" EXISTS(SELECT 1 FROM links WHERE links.user_id = ? AND links.purchase_disabled_at IS NULL AND links.banned_at IS NULL AND links.deleted_at IS NULL),"+
		" EXISTS(SELECT 1 FROM purchases WHERE purchases.purchaser_id = ? AND purchases.purchase_state = 'successful'),"+
		" EXISTS(SELECT 1 FROM webauthn_credentials WHERE webauthn_credentials.user_id = ?),"+
		" EXISTS(SELECT 1"+communities+" WHERE communities.seller_id = ? AND "+chatEnabled+"),"+
		" EXISTS(SELECT 1"+purchased+" AND purchases.purchaser_id = ?)", seller.id, seller.id, seller.id, u.id, u.id, u.id).
		Scan(&sells, &published, &bought, &passkeys, &ownCommunity, &purchasedCommunity); err != nil {
		return err
	}
	// has_accessible_communities?: then a guest purchase under the visitor's email.
	community := ownCommunity || purchasedCommunity
	if !community && u.email.Valid {
		if community, err = h.exists(ctx, "SELECT 1 AS one"+purchased+" AND purchases.email = ?"+
			" AND (purchases.purchaser_id IS NULL OR purchases.purchaser_id != ?) LIMIT 1", u.email.String, u.id); err != nil {
			return err
		}
	}
	// logged_in_user's payout keys read the visitor's compliance info and bank account,
	// current_seller's props the seller's.
	users := []*signedInUser{u}
	if seller != u {
		users = append(users, seller)
	}
	for _, x := range users {
		if x.info, err = h.complianceInfo(ctx, x.id); err != nil {
			return err
		}
		if x.bank, err = h.activeBankAccountType(ctx, x.id); err != nil {
			return err
		}
	}
	if u.loggedIn, err = h.loggedInUserProps(p, u, community); err != nil {
		return err
	}
	if u.currentSeller, err = h.currentSellerProps(p, seller, sells, published, bought); err != nil {
		return err
	}
	u.currentUser = rails.NewRHash().Sym("name", u.displayName(false)).Sym("avatar_url", u.avatarURL).Sym("impersonated_user", nil)
	// show_passkey_setup_prompt?: the visitor's own account, not the mobile app, and the sign-in
	// asked for it.
	if c, ok := p.Req.Cookie("is_gumroad_mobile_app"); seller == u && (!ok || rails.Blank(c)) {
		match, err := sessionInt(p.Session.Get("prompt_passkey_setup"), u.id)
		if err != nil {
			return err
		}
		u.promptPasskey = match && !passkeys
	}
	return nil
}

// loggedInUserProps is RenderingExtension#logged_in_user_props: the visitor's own keys, and the
// policies their role on the current seller allows.
func (h *handler) loggedInUserProps(p *page, u *signedInUser, community bool) (*rails.RHash, error) {
	ctx := p.Ctx
	memberships, err := h.teamMembershipsProps(p, u)
	if err != nil {
		return nil, err
	}
	confirmed := u.confirmedAt.Valid
	brand := false
	if confirmed {
		if brand, err = h.flag(ctx, "brand_accounts", u.id); err != nil {
			return nil, err
		}
	}
	legal, err := u.info.legalEntityCountryCode()
	if err != nil {
		return nil, err
	}
	// CreateBrandAccountService: NEW_ACCOUNT_CREATION_BLOCKED_COUNTRIES is IN alone, and only an
	// IndianBankAccount's country is IN.
	copied := legal != "" && legal != "IN" && u.bank != "" && u.bank != "CardBankAccount" && u.bank != "IndianBankAccount"
	navItems, err := h.promotedNavItems(ctx, u.id)
	if err != nil {
		return nil, err
	}
	lazyImages, err := h.flag(ctx, "lazy_load_offscreen_discover_images", u.id)
	if err != nil {
		return nil, err
	}
	// Each action's policy method, as the roles it lets in besides the owner.
	allowed := func(keys []string, roles ...string) *rails.RHash {
		r := rails.NewRHash()
		for _, k := range keys {
			r.Sym(k, p.hasRole(roles...))
		}
		return r
	}
	all := []string{teamAccountant, teamAdmin, teamMarketing, teamSupport}
	write := []string{teamAdmin, teamMarketing}
	policies := rails.NewRHash().
		Sym("affiliate_requests_onboarding_form", allowed([]string{"update"}, write...)).
		Sym("direct_affiliate", allowed([]string{"create", "update"}, write...)).
		Sym("collaborator", allowed([]string{"create", "update"}, teamAdmin)).
		Sym("product", allowed([]string{"create"}, write...)).
		Sym("product_review_response", allowed([]string{"update"}, teamAdmin, teamSupport)).
		Sym("balance", allowed([]string{"index", "export"}, teamAccountant, teamAdmin, teamSupport)).
		Sym("checkout_offer_code", allowed([]string{"create"}, write...)).
		Sym("checkout_form", allowed([]string{"update"}, write...)).
		Sym("upsell", allowed([]string{"create"}, write...)).
		Sym("settings_payments_user", allowed([]string{"show"}, teamAdmin)).
		Sym("settings_main_user", allowed([]string{"update_username"})).
		Sym("settings_profile", rails.NewRHash().Sym("manage_social_connections", p.hasRole()).Sym("update", p.hasRole(write...))).
		Sym("settings_third_party_analytics_user", allowed([]string{"update"}, teamAdmin)).
		Sym("installment", allowed([]string{"create"}, write...)).
		Sym("workflow", allowed([]string{"create"}, write...)).
		Sym("utm_link", allowed([]string{"index"}, all...)).
		Sym("community", rails.NewRHash().Sym("index", community)).
		Sym("churn", allowed([]string{"show"}, all...)).
		Sym("page", rails.NewRHash().Sym("index", p.hasRole(all...)).Sym("create", p.hasRole(write...)))
	return rails.NewRHash().
		Sym("id", nullString(u.externalID)).
		Sym("email", nullString(u.email)).
		Sym("name", nullString(u.name)).
		Sym("avatar_url", u.avatarURL).
		Sym("confirmed", confirmed).
		Sym("team_memberships", memberships).
		Sym("can_create_brand_account", confirmed && brand).
		Sym("has_payout_setup_to_port", rails.Present(u.payAddr.String) || copied).
		Sym("can_port_bank_payout_setup", legal != "IN").
		Sym("will_copy_bank_payout", copied).
		Sym("policies", policies).
		Sym("promoted_nav_items", navItems).
		Sym("lazy_load_offscreen_discover_images", lazyImages), nil
}

// teamMembershipsProps is UserMembershipsPresenter#props over the visitor's memberships.
func (h *handler) teamMembershipsProps(p *page, u *signedInUser) ([]any, error) {
	list := u.memberships
	out := []any{}
	if len(list) == 0 {
		return out, nil
	}
	if !slices.ContainsFunc(list, func(m *teamMembership) bool { return m.role.String == teamOwner }) {
		// Rails notifies about the missing owner row and renders none.
		web.Logger(p.Req.HTTP).Warn("missing owner team membership", "user_id", u.id)
		return out, nil
	}
	sellers := map[int64]*signedInUser{u.id: u, p.currentSeller.id: p.currentSeller}
	var others []int64
	for _, m := range list {
		if _, ok := sellers[m.sellerID]; !ok && !slices.Contains(others, m.sellerID) {
			others = append(others, m.sellerID)
		}
	}
	if len(others) > 0 {
		rows, err := h.c.DB.QueryContext(p.Ctx, "SELECT "+userColumns+", users.email, users.unconfirmed_email FROM users"+
			" WHERE users.id IN ("+placeholders(len(others))+")", int64Args(others)...)
		if err != nil {
			return nil, err
		}
		defer rows.Close()
		var loaded []*signedInUser
		for rows.Next() {
			s := &signedInUser{}
			if err := rows.Scan(append(s.user.dest(), &s.email, &s.unconfirmedEmail)...); err != nil {
				return nil, err
			}
			loaded = append(loaded, s)
		}
		if err := rows.Err(); err != nil {
			return nil, err
		}
		rows.Close()
		for _, s := range loaded {
			if s.avatarURL, err = h.avatarURL(p, s.id); err != nil {
				return nil, err
			}
			sellers[s.id] = s
		}
	}
	for _, m := range list {
		seller := sellers[m.sellerID]
		if seller == nil {
			// Gone since the join found it.
			return nil, fallback("team membership seller")
		}
		out = append(out, rails.NewRHash().
			Sym("id", h.c.IDs.Encrypt(m.id)).
			Sym("seller_name", seller.displayName(true)).
			Sym("seller_avatar_url", seller.avatarURL).
			Sym("has_some_read_only_access", m.role.String != teamOwner && m.role.String != teamAdmin).
			Sym("is_selected", m.sellerID == p.currentSeller.id))
	}
	return out, nil
}

// promotedNavItems is User#promoted_nav_item_keys. The pluck has no ORDER BY, so the statement
// is Rails' own, for MySQL to take the same plan.
func (h *handler) promotedNavItems(ctx context.Context, userID int64) ([]any, error) {
	rows, err := h.c.DB.QueryContext(ctx, "SELECT `dashboard_nav_promotions`.`nav_item` FROM `dashboard_nav_promotions`"+
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
		return false, fallback("passkey prompt session")
	}
	return string(n) == strconv.FormatInt(id, 10), nil
}

// currentSellerProps is UserPresenter#as_current_seller for the current seller, u.
func (h *handler) currentSellerProps(p *page, u *signedInUser, sells, published, bought bool) (*rails.RHash, error) {
	ctx := p.Ctx
	zone, offset, err := railsTimeZone(u.timezone.String, p.Req.Now)
	if err != nil {
		return nil, err
	}
	canPublish, err := h.canPublishProducts(ctx, u)
	if err != nil {
		return nil, err
	}
	var blocked any
	if !canPublish {
		if blocked, err = h.publishBlockedReason(ctx, u.id); err != nil {
			return nil, err
		}
	}
	var subdomain any
	if rails.Present(sellerUsername(&u.user)) {
		subdomain = h.userSubdomain(&u.user)
	}
	noRail, err := noPayoutRail(u.bank, u.info)
	if err != nil {
		return nil, err
	}
	met, unsupported := true, false
	if u.info != nil {
		if unsupported, err = u.info.guardianUnsupported(p.Req.Now); err != nil {
			return nil, err
		}
		if met, err = h.guardianRequirementMet(ctx, u.info, p.Req.Now); err != nil {
			return nil, err
		}
	}
	profile, err := h.sellerProfile(ctx, u.id)
	if err != nil {
		return nil, err
	}
	or := func(s *string, def string) string {
		if s == nil {
			return def
		}
		return *s
	}
	return rails.NewRHash().
		Sym("id", nullString(u.externalID)).
		Sym("email", nullString(u.email)).
		Sym("name", u.displayName(true)).
		Sym("subdomain", subdomain).
		Sym("avatar_url", u.avatarURL).
		Sym("is_buyer", !sells && bought).
		Sym("time_zone", rails.NewRHash().Sym("name", zone).Sym("offset", int64(offset))).
		Sym("has_published_products", published).
		Sym("can_publish_products", canPublish).
		Sym("publish_blocked_reason", blocked).
		Sym("no_payout_rail_in_compliance_country", noRail).
		Sym("legal_guardian_requirement_met", met).
		Sym("legal_guardian_unsupported", unsupported).
		Sym("is_name_invalid_for_email_delivery", rails.Present(u.name.String) && strings.Contains(u.name.String, ":")).
		Sym("profile_background_color", or(profile.BackgroundColor, "#ffffff")).
		Sym("profile_highlight_color", or(profile.HighlightColor, "#ff90e8")).
		Sym("profile_font", or(profile.Font, "ABC Favorit")), nil
}

// railsTimeZone is ActiveSupport::TimeZone[name]'s tzinfo name and observed offset now. Saves
// keep the column to MAPPING's names, so anything else goes to Rails.
func railsTimeZone(name string, now time.Time) (string, int, error) {
	id, ok := timeZoneMapping[name]
	if !ok {
		return "", 0, fallback("time zone")
	}
	loc, err := time.LoadLocation(id)
	if err != nil {
		return "", 0, fallback("time zone")
	}
	_, offset := now.In(loc).Zone()
	return id, offset, nil
}

// canPublishProducts is User#can_publish_products? for a seller who isn't staff.
func (h *handler) canPublishProducts(ctx context.Context, u *signedInUser) (bool, error) {
	rows, err := h.c.DB.QueryContext(ctx, "SELECT merchant_accounts.charge_processor_id, merchant_accounts.json_data FROM merchant_accounts"+
		" WHERE merchant_accounts.user_id = ? AND merchant_accounts.deleted_at IS NULL AND merchant_accounts.charge_processor_alive_at IS NOT NULL"+
		" AND merchant_accounts.charge_processor_deleted_at IS NULL AND merchant_accounts.charge_processor_id IN ('stripe', 'paypal')", u.id)
	if err != nil {
		return false, err
	}
	defer rows.Close()
	found := false
	for rows.Next() {
		var processor string
		var data sql.NullString
		if err := rows.Scan(&processor, &data); err != nil {
			return false, err
		}
		if processor == "stripe" {
			// Rails classifies the Stripe rows by their json_data, raising on one it can't read.
			if _, _, err := merchantAccountConnect(data); err != nil {
				return false, err
			}
		}
		found = true
	}
	if err := rows.Err(); err != nil {
		return false, err
	}
	return found || rails.Present(u.payAddr.String), nil
}

// publishBlockedReason is publish_blocked_reason_for: whether staff rejected the seller's payout
// setup in a note.
func (h *handler) publishBlockedReason(ctx context.Context, userID int64) (string, error) {
	if h.c.Page.GumroadAdminID == 0 {
		return "", fallback("gumroad admin id")
	}
	rows, err := h.c.DB.QueryContext(ctx, "SELECT comments.json_data FROM comments WHERE comments.commentable_id = ?"+
		" AND comments.commentable_type = 'User' AND comments.comment_type = 'payout_note' AND comments.deleted_at IS NULL"+
		" AND comments.author_id = ? AND (json_data LIKE '%payout_setup_rejection%') ORDER BY comments.created_at DESC, comments.id DESC",
		userID, h.c.Page.GumroadAdminID)
	if err != nil {
		return "", err
	}
	defer rows.Close()
	for rows.Next() {
		var data sql.NullString
		if err := rows.Scan(&data); err != nil {
			return "", err
		}
		j, ok := parseJSONData(data)
		if !ok {
			return "", fallback("comment json_data")
		}
		if j.get("payout_setup_rejection") == true {
			return "payout_setup_rejected", nil
		}
	}
	return "no_payout_method", rows.Err()
}

// activeBankAccountType is active_bank_account's STI type, "" without one; a type Rails can't
// load goes to Rails.
func (h *handler) activeBankAccountType(ctx context.Context, userID int64) (string, error) {
	var typ sql.NullString
	err := h.c.DB.QueryRowContext(ctx, "SELECT bank_accounts.type FROM bank_accounts WHERE bank_accounts.user_id = ?"+
		" AND bank_accounts.deleted_at IS NULL ORDER BY bank_accounts.id ASC LIMIT 1", userID).Scan(&typ)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	if !bankAccountTypes[typ.String] {
		return "", fallback("bank account type")
	}
	return typ.String, nil
}

// noPayoutRail is no_payout_rail_in_compliance_country?.
func noPayoutRail(bank string, info *complianceInfo) (bool, error) {
	if bank != "" {
		return false, nil
	}
	code, err := info.legalEntityCountryCode()
	if err != nil || code == "" {
		return false, err
	}
	native := slices.Contains(nativePayoutCountries, code) && (code != "AE" || info.isBusiness)
	paypal := code
	if slices.Contains(usOutlyingAreas, code) {
		paypal = "US"
	}
	return !native && !slices.Contains(paypalPayoutCountries, paypal), nil
}

type complianceInfo struct {
	country, businessCountry sql.NullString
	isBusiness               bool
	birthday                 db.NullTime
	guardianID               sql.NullInt64
}

func (h *handler) complianceInfo(ctx context.Context, userID int64) (*complianceInfo, error) {
	c := &complianceInfo{}
	var business sql.NullBool
	err := h.c.DB.QueryRowContext(ctx, "SELECT user_compliance_info.country, user_compliance_info.business_country, user_compliance_info.is_business,"+
		" user_compliance_info.birthday, user_compliance_info.guardian_id FROM user_compliance_info WHERE user_compliance_info.user_id = ?"+
		" AND user_compliance_info.deleted_at IS NULL ORDER BY user_compliance_info.id DESC LIMIT 1", userID).
		Scan(&c.country, &c.businessCountry, &business, &c.birthday, &c.guardianID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	c.isBusiness = business.Bool
	return c, err
}

// complianceCountry is Compliance::Countries.find_by_name(name)&.alpha2, "" for nil; a name this
// port has no answer for goes to Rails.
func complianceCountry(name sql.NullString) (string, error) {
	if rails.Blank(name.String) {
		return "", nil
	}
	code, ok := complianceCountryCodes[name.String]
	if !ok {
		return "", fallback("compliance country")
	}
	return code, nil
}

// legalEntityCountryCode is the business country's code for a business that has one, else the
// individual's; "" without compliance info.
func (c *complianceInfo) legalEntityCountryCode() (string, error) {
	if c == nil {
		return "", nil
	}
	if c.isBusiness {
		code, err := complianceCountry(c.businessCountry)
		if err != nil || code != "" {
			return code, err
		}
	}
	return complianceCountry(c.country)
}

// underGuardianAge is under_legal_guardian_age?: born after this day 18 years ago, in UTC.
func (c *complianceInfo) underGuardianAge(now time.Time) bool {
	if !c.birthday.Valid {
		return false
	}
	t := rails.AddYears(now.UTC(), -guardianRequiredBelowAge)
	cutoff := time.Date(t.Year(), t.Month(), t.Day(), 0, 0, 0, 0, time.UTC)
	b := c.birthday.Time
	return time.Date(b.Year(), b.Month(), b.Day(), 0, 0, 0, 0, time.UTC).After(cutoff)
}

// guardianUnsupported is legal_guardian_unsupported?.
func (c *complianceInfo) guardianUnsupported(now time.Time) (bool, error) {
	if !c.underGuardianAge(now) {
		return false, nil
	}
	code, err := complianceCountry(c.country)
	return code != "" && code != "US", err
}

// guardianRequirementMet is legal_guardian_requirement_met?.
func (h *handler) guardianRequirementMet(ctx context.Context, c *complianceInfo, now time.Time) (bool, error) {
	if unsupported, err := c.guardianUnsupported(now); err != nil || unsupported {
		return false, err
	}
	if !c.underGuardianAge(now) {
		return true, nil
	}
	if code, err := complianceCountry(c.country); err != nil || code != "US" {
		return true, err
	}
	if !c.guardianID.Valid {
		return false, nil
	}
	var g struct {
		deletedAt, dob, acceptedAt                                  db.NullTime
		first, last, email, street, city, state, zip, country, code sql.NullString
		taxID                                                       []byte
		tosIP                                                       sql.NullString
		accepted                                                    sql.NullBool
	}
	err := h.c.DB.QueryRowContext(ctx, "SELECT guardians.deleted_at, guardians.first_name, guardians.last_name, guardians.email,"+
		" guardians.date_of_birth, guardians.street_address, guardians.city, guardians.state, guardians.zip_code, guardians.country,"+
		" guardians.country_code, guardians.individual_tax_id, guardians.stripe_tos_accepted, guardians.stripe_tos_accepted_at,"+
		" guardians.stripe_tos_ip FROM guardians WHERE guardians.id = ? LIMIT 1", c.guardianID.Int64).
		Scan(&g.deletedAt, &g.first, &g.last, &g.email, &g.dob, &g.street, &g.city, &g.state, &g.zip, &g.country, &g.code, &g.taxID,
			&g.accepted, &g.acceptedAt, &g.tosIP)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	present := func(fields ...sql.NullString) bool {
		for _, f := range fields {
			if rails.Blank(f.String) {
				return false
			}
		}
		return true
	}
	if g.deletedAt.Valid || !present(g.first, g.last, g.email) || !g.dob.Valid || !present(g.street, g.city) {
		return false, nil
	}
	// state_required? reads the country only once the fields before it are in.
	stateCode := g.code.String
	if rails.Blank(stateCode) {
		if stateCode, err = complianceCountry(g.country); err != nil {
			return false, err
		}
	}
	if slices.Contains(guardianStateCountries, stateCode) && rails.Blank(g.state.String) {
		return false, nil
	}
	return present(g.zip, g.country) && len(g.taxID) > 0 && g.accepted.Bool && g.acceptedAt.Valid && rails.Present(g.tosIP.String), nil
}
