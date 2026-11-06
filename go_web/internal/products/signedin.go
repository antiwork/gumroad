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

const (
	// guardianRequiredBelowAge is UserComplianceInfo::GUARDIAN_REQUIRED_BELOW_AGE.
	guardianRequiredBelowAge = 18
	// minSalesCentsForStoreAgent is User::MIN_SALES_CENTS_VALUE_FOR_STORE_AGENT.
	minSalesCentsForStoreAgent = 10_000
)

var (
	// promotableNavItems is DashboardNav::PROMOTABLE_ITEMS.
	promotableNavItems = []string{"agent", "profile", "pages", "collaborators", "checkout", "emails", "workflows", "analytics",
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
	// The signed-in share's props, in the order the page sets them.
	loggedIn, currentSeller, currentUser *rails.RHash
	promptPasskey                        bool
}

func (h *handler) loadSignedInUser(ctx context.Context, id int64) (*signedInUser, error) {
	u := &signedInUser{}
	dest := append(u.user.dest(), &u.email, &u.unconfirmedEmail, &u.payAddr, &u.timezone, &u.currencyType, &u.confirmedAt)
	if err := h.c.DB.QueryRowContext(ctx, "SELECT "+userColumns+", users.email, users.unconfirmed_email, users.payment_address,"+
		" users.timezone, users.currency_type, users.confirmed_at FROM users WHERE users.id = ? LIMIT 1", id).Scan(dest...); err != nil {
		return nil, err
	}
	var err error
	u.avatarURL, err = h.avatarURL(ctx, id)
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

// loadViewer loads the signed-in visitor viewing the product as themselves, and the signed-in
// share's props. Prepare has sent staff, and with them impersonation, to Rails.
func (h *handler) loadViewer(p *page, prod *product) error {
	logged := p.Auth.LoggedInUser()
	switch {
	case logged == nil:
		return nil
	case p.Auth.CurrentSeller == nil || p.Auth.CurrentSeller.ID != logged.ID:
		return fallback("signed in as another seller")
	}
	if err := h.viewerHasNoPart(p, prod, logged.ID); err != nil {
		return err
	}
	u, err := h.loadSignedInUser(p.Ctx, logged.ID)
	if err != nil {
		return err
	}
	if err := h.signedInProps(p, u); err != nil {
		return err
	}
	if u.wishlists, err = h.loadViewerWishlists(p.Ctx, u.id); err != nil {
		return err
	}
	p.viewer = u
	return nil
}

// viewerHasNoPart goes to Rails for a product the visitor bought or collaborates on:
// purchase_info_for_product_page takes their own purchases, in any state, over the browser's,
// and collaborator_for? opens the editor's props.
func (h *handler) viewerHasNoPart(p *page, prod *product, userID int64) error {
	bought, err := h.exists(p.Ctx, "SELECT 1 FROM purchases WHERE purchases.purchaser_id = ? AND purchases.link_id = ? LIMIT 1", userID, prod.id)
	if err != nil || bought {
		return firstErr(err, fallback("signed-in purchase"))
	}
	if !p.hasCollaborator {
		return nil
	}
	collaborates, err := h.exists(p.Ctx, "SELECT 1 FROM affiliates INNER JOIN affiliates_links ON affiliates_links.affiliate_id = affiliates.id"+
		" WHERE affiliates.type = 'Collaborator' AND affiliates.affiliate_user_id = ? AND affiliates_links.link_id = ? LIMIT 1", userID, prod.id)
	if err != nil || collaborates {
		return firstErr(err, fallback("product's collaborator"))
	}
	return nil
}

// viewerCurrency is ProfileSectionsPresenter's currency_code: the visitor's currency_type.
func viewerCurrency(p *page) any {
	if p.viewer != nil && p.viewer.currencyType.Valid {
		return p.viewer.currencyType.String
	}
	return "usd"
}

// viewerWishlist is one of the visitor's alive wishlists and its alive items.
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

// viewerWishlists is product_props' wishlists: each of the visitor's wishlists, with what it
// holds of the product.
func (h *handler) viewerWishlists(p *page, prod *product) []any {
	out := []any{}
	if p.viewer == nil {
		return out
	}
	for _, w := range p.viewer.wishlists {
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

// signedInProps builds the signed-in share: logged_in_user and current_seller, which
// RenderingExtension builds for the visitor as their own seller, then current_user and
// prompt_passkey_setup. Whatever goes to Rails is read first.
func (h *handler) signedInProps(p *page, u *signedInUser) error {
	ctx := p.Ctx
	storeAgent, err := h.eligibleForStoreAgent(ctx, u)
	if err != nil {
		return err
	}
	if _, ok := timeZoneMapping[u.timezone.String]; !ok {
		return fallback("time zone")
	}
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
		" EXISTS(SELECT 1"+purchased+" AND purchases.purchaser_id = ?)", u.id, u.id, u.id, u.id, u.id, u.id).
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
	if u.info, err = h.complianceInfo(ctx, u.id); err != nil {
		return err
	}
	if u.bank, err = h.activeBankAccountType(ctx, u.id); err != nil {
		return err
	}
	if u.loggedIn, err = h.loggedInUserProps(p, u, community, storeAgent); err != nil {
		return err
	}
	if u.currentSeller, err = h.currentSellerProps(p, u, sells, published, bought); err != nil {
		return err
	}
	u.currentUser = rails.NewRHash().Sym("name", u.displayName(false)).Sym("avatar_url", u.avatarURL).Sym("impersonated_user", nil)
	// show_passkey_setup_prompt?: not the mobile app, and the sign-in asked for it.
	if c, ok := p.Req.Cookie("is_gumroad_mobile_app"); !ok || rails.Blank(c) {
		match, err := sessionInt(p.Session.Get("prompt_passkey_setup"), u.id)
		if err != nil {
			return err
		}
		u.promptPasskey = match && !passkeys
	}
	return nil
}

// loggedInUserProps is RenderingExtension#logged_in_user_props for the visitor as their own
// seller, for whom every role check passes.
func (h *handler) loggedInUserProps(p *page, u *signedInUser, community, storeAgent bool) (*rails.RHash, error) {
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
	yes := func(keys ...string) *rails.RHash {
		r := rails.NewRHash()
		for _, k := range keys {
			r.Sym(k, true)
		}
		return r
	}
	policies := rails.NewRHash().
		Sym("affiliate_requests_onboarding_form", yes("update")).
		Sym("direct_affiliate", yes("create", "update")).
		Sym("collaborator", yes("create", "update")).
		Sym("product", yes("create")).
		Sym("product_review_response", yes("update")).
		Sym("balance", yes("index", "export")).
		Sym("checkout_offer_code", yes("create")).
		Sym("checkout_form", yes("update")).
		Sym("upsell", yes("create")).
		Sym("settings_payments_user", yes("show")).
		Sym("settings_main_user", yes("update_username")).
		Sym("settings_profile", yes("manage_social_connections", "update")).
		Sym("settings_third_party_analytics_user", yes("update")).
		Sym("installment", yes("create")).
		Sym("workflow", yes("create")).
		Sym("utm_link", yes("index")).
		Sym("community", rails.NewRHash().Sym("index", community)).
		Sym("churn", yes("show")).
		Sym("page", yes("index", "create")).
		Sym("user", rails.NewRHash().Sym("view_store_agent", true).Sym("use_store_agent", storeAgent))
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

// teamMembershipsProps is UserMembershipsPresenter#props.
func (h *handler) teamMembershipsProps(p *page, u *signedInUser) ([]any, error) {
	rows, err := h.c.DB.QueryContext(p.Ctx, "SELECT team_memberships.id, team_memberships.seller_id, team_memberships.role"+
		" FROM team_memberships INNER JOIN users ON users.id = team_memberships.seller_id"+
		" WHERE team_memberships.user_id = ? AND team_memberships.deleted_at IS NULL AND users.deleted_at IS NULL"+
		" ORDER BY team_memberships.last_accessed_at DESC, team_memberships.created_at DESC", u.id)
	if err != nil {
		return nil, err
	}
	type membership struct {
		id, sellerID int64
		role         string
	}
	var list []membership
	for rows.Next() {
		var m membership
		var role sql.NullString
		if err := rows.Scan(&m.id, &m.sellerID, &role); err != nil {
			rows.Close()
			return nil, err
		}
		m.role = role.String
		list = append(list, m)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	out := []any{}
	if len(list) == 0 {
		return out, nil
	}
	if !slices.ContainsFunc(list, func(m membership) bool { return m.role == "owner" }) {
		// Rails notifies about the missing owner row and renders none.
		web.Logger(p.Req.HTTP).Warn("missing owner team membership", "user_id", u.id)
		return out, nil
	}
	if len(list) > 1 {
		// Rows tied on both sort columns come back in no defined order.
		return nil, fallback("team memberships")
	}
	// The one row is the owner's, whose seller is the visitor.
	m := list[0]
	return append(out, rails.NewRHash().
		Sym("id", h.c.IDs.Encrypt(m.id)).
		Sym("seller_name", u.displayName(true)).
		Sym("seller_avatar_url", u.avatarURL).
		Sym("has_some_read_only_access", m.role != "owner" && m.role != "admin").
		Sym("is_selected", m.sellerID == u.id)), nil
}

// eligibleForStoreAgent is User#eligible_for_store_agent?.
func (h *handler) eligibleForStoreAgent(ctx context.Context, u *signedInUser) (bool, error) {
	if !u.confirmedAt.Valid || u.riskState.String == "suspended_for_tos_violation" || u.riskState.String == "suspended_for_fraud" {
		return false, nil
	}
	completed, err := h.exists(ctx, "SELECT 1 AS one FROM payments WHERE payments.user_id = ? AND payments.state = 'completed' LIMIT 1", u.id)
	if err != nil {
		return false, err
	}
	if !completed {
		// made_a_successful_sale_with_a_stripe_connect_or_paypal_connect_account?
		var ids []int64
		rows, err := h.c.DB.QueryContext(ctx, "SELECT merchant_accounts.id FROM merchant_accounts WHERE merchant_accounts.user_id = ?"+
			" AND ((merchant_accounts.charge_processor_id = 'stripe' AND (json_data->>'$.meta.stripe_connect' = 'true')"+
			" AND merchant_accounts.user_id IS NOT NULL) OR merchant_accounts.charge_processor_id = 'paypal')", u.id)
		if err != nil {
			return false, fallback("merchant account json_data")
		}
		for rows.Next() {
			var id int64
			if err := rows.Scan(&id); err != nil {
				rows.Close()
				return false, err
			}
			ids = append(ids, id)
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return false, fallback("merchant account json_data")
		}
		if len(ids) == 0 {
			return false, nil
		}
		if completed, err = h.exists(ctx, "SELECT 1 AS one FROM purchases WHERE purchases.seller_id = ?"+
			" AND purchases.purchase_state IN ('successful','preorder_authorization_successful','gift_receiver_purchase_successful')"+
			" AND (purchases.stripe_refunded IS NULL OR purchases.stripe_refunded = 0)"+
			" AND (purchases.chargeback_date IS NULL OR (purchases.chargeback_date IS NOT NULL AND purchases.flags & 512 != 0))"+
			" AND (purchases.flags & 32 = 0) AND purchases.merchant_account_id IN ("+placeholders(len(ids))+") LIMIT 1",
			append([]any{u.id}, int64Args(ids)...)...); err != nil || !completed {
			return false, err
		}
	}
	if h.c.Page.Search == nil {
		return false, fallback("store agent sales total")
	}
	total, err := h.salesCentsTotal(ctx, u.id)
	return total >= minSalesCentsForStoreAgent, err
}

// salesCentsTotal is User::Stats#sales_cents_total: revenue as seller, summed as Floats in
// Rails' order and truncated, plus revenue as affiliate.
func (h *handler) salesCentsTotal(ctx context.Context, userID int64) (int64, error) {
	filter := func(owner any) []any {
		return []any{owner, map[string]any{"term": map[string]any{"stripe_refunded": false}},
			map[string]any{"term": map[string]any{"not_chargedback_or_chargedback_reversed": true}},
			map[string]any{"terms": map[string]any{"purchase_state": []string{"successful"}}}}
	}
	body := func(owner any, aggs map[string]any) map[string]any {
		return map[string]any{"query": map[string]any{"bool": map[string]any{
			"filter":   filter(owner),
			"must_not": []any{map[string]any{"term": map[string]any{"selected_flags": "is_bundle_product_purchase"}}},
			"must":     []any{map[string]any{"range": map[string]any{"price_cents": map[string]any{"gt": 0}}}},
		}}, "from": 0, "size": 0, "_source": false, "aggs": aggs}
	}
	// PurchaseSearchService's seller sums, in the order revenue_as_seller adds and subtracts them.
	sellerSums := []struct {
		field string
		sign  float64
	}{{"price_cents", 1}, {"fee_cents", -1}, {"amount_refunded_cents", -1}, {"fee_refunded_cents", 1},
		{"affiliate_credit_amount_cents", -1}, {"affiliate_credit_amount_partially_refunded_cents", 1},
		{"direct_affiliate_credit_amount_cents", -1}, {"direct_affiliate_credit_amount_partially_refunded_cents", 1}}
	aggs := map[string]any{}
	for _, s := range sellerSums {
		aggs[s.field+"_total"] = map[string]any{"sum": map[string]any{"field": s.field}}
	}
	var seller struct {
		Aggregations map[string]struct {
			Value float64 `json:"value"`
		} `json:"aggregations"`
	}
	if err := h.c.Page.Search.Search(ctx, "purchases", body(map[string]any{"terms": map[string]any{"seller_id": []int64{userID}}}, aggs), &seller); err != nil {
		return 0, err
	}
	revenue := 0.0
	for _, s := range sellerSums {
		revenue += s.sign * seller.Aggregations[s.field+"_total"].Value
	}

	prefixes := []string{"affiliate_credit", "direct_affiliate_credit"}
	aggs = map[string]any{}
	for _, prefix := range prefixes {
		for _, measure := range []string{"amount_cents", "fee_cents", "amount_partially_refunded_cents", "fee_partially_refunded_cents"} {
			aggs[prefix+"_"+measure+"_own"] = map[string]any{"filter": map[string]any{"term": map[string]any{prefix + "_affiliate_user_id": userID}},
				"aggs": map[string]any{"total": map[string]any{"sum": map[string]any{"field": prefix + "_" + measure}}}}
		}
	}
	owner := map[string]any{"bool": map[string]any{"minimum_should_match": 1, "should": []any{
		map[string]any{"terms": map[string]any{"affiliate_credit_affiliate_user_id": []int64{userID}}},
		map[string]any{"terms": map[string]any{"direct_affiliate_credit_affiliate_user_id": []int64{userID}}}}}}
	var affiliate struct {
		Aggregations map[string]struct {
			Total struct {
				Value float64 `json:"value"`
			} `json:"total"`
		} `json:"aggregations"`
	}
	if err := h.c.Page.Search.Search(ctx, "purchases", body(owner, aggs), &affiliate); err != nil {
		return 0, err
	}
	var earned, refunded int64
	for _, prefix := range prefixes {
		earned += int64(affiliate.Aggregations[prefix+"_amount_cents_own"].Total.Value)
		refunded += int64(affiliate.Aggregations[prefix+"_amount_partially_refunded_cents_own"].Total.Value)
	}
	return int64(revenue) + earned - refunded, nil
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

// currentSellerProps is UserPresenter#as_current_seller for the visitor's own account.
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

// canPublishProducts is User#can_publish_products? for a visitor who isn't staff.
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
