package products

import (
	"context"
	"database/sql"
	"errors"
	"strings"

	"github.com/antiwork/gumroad/go_web/internal/customdomain"
	"github.com/antiwork/gumroad/go_web/internal/db"
	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// Purchase flag bits (has_flags in purchase.rb).
const (
	purchaseIsAdditionalContribution       int64 = 1 << 0
	purchaseIsOriginalSubscription         int64 = 1 << 2
	purchaseIsPreorderAuthorization        int64 = 1 << 3
	purchaseIsGiftReceiver                 int64 = 1 << 5
	purchaseIsGiftSender                   int64 = 1 << 6
	purchaseChargebackReversed             int64 = 1 << 9
	purchaseWasTaxable                     int64 = 1 << 12
	purchaseIsArchivedOriginalSubscription int64 = 1 << 17
	purchaseIsFreeTrial                    int64 = 1 << 18
	purchaseExcludesProductReview          int64 = 1 << 22
	purchaseIsAccessRevoked                int64 = 1 << 24
	purchaseIsBundle                       int64 = 1 << 25
	purchaseIsBundleProduct                int64 = 1 << 26
	purchaseIsCommissionCompletion         int64 = 1 << 29
)

// Link flag bits (has_flags in link.rb).
const (
	productRefundPolicyEnabled int64 = 1 << iota
	productIsRecurringBilling
	productFreeTrialEnabled
	productIsInPreorderState
	productArchived
	productIsDuplicating
	productIsLicensed
	productIsPhysical
	productSkusEnabled
	productBlockAccessAfterCancellation
	productIsPriceTaxExclusiveDeprecated
	productShouldIncludeLastPost
	productFromBundleMarketing
	productQuantityEnabled
	productHasOutdatedPurchases
	productIsAdult
	productDisplayReviews
	productAllowDoubleCharges
	productIsTieredMembership
	productShouldShowAllPosts
	productIsMultiseatLicense
	productShouldShowSalesCount
	productIsEpublication
	productTranscodeVideosOnPurchase
	productSameRichContentForAllVariants
	productIsBundle
	productPPPDisabled
	productIsCollab
	productUnpublishedByAdmin
	productCommunityChatEnabled
	productCreatedViaCLI
	productDeprecatedModeratedByIffy
	productHideSoldOutVariants
	productHideBundleReviews
	productWaitlistEnabled
)

// User flag bits this page reads (has_flags in user.rb).
const (
	userSkipFreeSaleAnalytics        int64 = 1 << 1
	userPPPEnabled                   int64 = 1 << 2
	userDisableThirdPartyAnalytics   int64 = 1 << 11
	userCheckMerchantAccountIsLinked int64 = 1 << 24
	userAllAdultProducts             int64 = 1 << 31
	userRefundPolicyEnabled          int64 = 1 << 45
	userRefundPolicyEnforced         int64 = 1 << 52
	userProductPageStorefrontEnabled int64 = 1 << 57
	userHideFollowForm               int64 = 1 << 59
)

// Link#purchase_type.
const (
	purchaseTypeBuyOnly    = 0
	purchaseTypeRentOnly   = 1
	purchaseTypeBuyAndRent = 2
)

// Price flag bits.
const priceIsRental int64 = 1 << 0

// BaseVariant flag bits.
const baseVariantIsDefaultSku int64 = 1 << 0

// product is the links row.
type product struct {
	id, userID          int64
	name                string
	uniquePermalink     sql.NullString
	customPermalink     sql.NullString
	description         sql.NullString
	purchaseType        sql.NullInt64
	purchaseDisabledAt  db.NullTime
	deletedAt, bannedAt db.NullTime
	priceCurrencyType   sql.NullString
	customizablePrice   sql.NullBool
	maxPurchaseCount    sql.NullInt64
	suggestedPriceCents sql.NullInt64
	draft               sql.NullBool
	flags               int64
	jsonData            sql.NullString
	durationInMonths    sql.NullInt64
	nativeType          string
	defaultOfferCodeID  sql.NullInt64
	requireShipping     sql.NullBool
	// subscriptionDuration and freeTrialDurationUnit are enums; see enumName.
	subscriptionDuration                           sql.NullInt64
	freeTrialDurationUnit, freeTrialDurationAmount sql.NullInt64
}

const productColumns = `links.id, links.user_id, links.name, links.unique_permalink, links.custom_permalink,
	links.description, links.purchase_type, links.purchase_disabled_at, links.deleted_at, links.banned_at,
	links.price_currency_type, links.customizable_price, links.max_purchase_count, links.suggested_price_cents,
	links.draft, links.flags, links.json_data, links.duration_in_months, links.native_type,
	links.default_offer_code_id, links.require_shipping, links.subscription_duration,
	links.free_trial_duration_unit, links.free_trial_duration_amount`

func (p *product) dest() []any {
	return []any{&p.id, &p.userID, &p.name, &p.uniquePermalink, &p.customPermalink, &p.description, &p.purchaseType,
		&p.purchaseDisabledAt, &p.deletedAt, &p.bannedAt, &p.priceCurrencyType, &p.customizablePrice,
		&p.maxPurchaseCount, &p.suggestedPriceCents, &p.draft, &p.flags, &p.jsonData, &p.durationInMonths,
		&p.nativeType, &p.defaultOfferCodeID, &p.requireShipping, &p.subscriptionDuration,
		&p.freeTrialDurationUnit, &p.freeTrialDurationAmount}
}

// Link's subscription_duration and free_trial_duration_unit enums.
var (
	subscriptionDurations = []string{"monthly", "yearly", "quarterly", "biannually", "every_two_years"}
	freeTrialUnits        = []string{"week", "month"}
)

// enumName is an enum column's name, "" for NULL; ok is false for a value the enum doesn't map.
func enumName(names []string, n sql.NullInt64) (name string, ok bool) {
	if !n.Valid {
		return "", true
	}
	if n.Int64 < 0 || n.Int64 >= int64(len(names)) {
		return "", false
	}
	return names[n.Int64], true
}

func (p *product) subscriptionDurationName() (string, bool) {
	return enumName(subscriptionDurations, p.subscriptionDuration)
}

func (p *product) freeTrialUnitName() (string, bool) {
	return enumName(freeTrialUnits, p.freeTrialDurationUnit)
}

func (p *product) is(flag int64) bool { return p.flags&flag != 0 }

func (p *product) rentOnly() bool { return p.purchaseType.Int64 == purchaseTypeRentOnly }

// alive is Link#alive?.
func (p *product) alive() bool {
	return !p.purchaseDisabledAt.Valid && !p.bannedAt.Valid && !p.deletedAt.Valid
}

// published is Link#published?.
func (p *product) published() bool {
	return !p.deletedAt.Valid && !p.purchaseDisabledAt.Valid && !p.draft.Bool
}

// acceptsWaitlistSignups is Link#accepts_waitlist_signups?.
func (p *product) acceptsWaitlistSignups() bool {
	return p.is(productWaitlistEnabled) && !p.published() && !p.deletedAt.Valid && !p.bannedAt.Valid && !p.is(productUnpublishedByAdmin)
}

// generalPermalink is Link#general_permalink.
func (p *product) generalPermalink() string {
	if rails.Present(p.customPermalink.String) {
		return p.customPermalink.String
	}
	return p.uniquePermalink.String
}

// user is the users row, as much of it as the page reads.
type user struct {
	id              int64
	name            sql.NullString
	username        sql.NullString
	externalID      sql.NullString
	deletedAt       db.NullTime
	flags           int64
	twitterHandle   sql.NullString
	verified        sql.NullBool
	googleAnalytics sql.NullString
	facebookPixel   sql.NullString
	jsonData        sql.NullString
	pppLimit        sql.NullInt64
	riskState       sql.NullString
}

const userColumns = `users.id, users.name, users.username, users.external_id, users.deleted_at, users.flags,
	users.twitter_handle, users.verified, users.google_analytics_id, users.facebook_pixel_id, users.json_data,
	users.purchasing_power_parity_limit, users.user_risk_state`

func (u *user) dest() []any {
	return []any{&u.id, &u.name, &u.username, &u.externalID, &u.deletedAt, &u.flags, &u.twitterHandle, &u.verified,
		&u.googleAnalytics, &u.facebookPixel, &u.jsonData, &u.pppLimit, &u.riskState}
}

func (u *user) is(flag int64) bool { return u.flags&flag != 0 }

// subdomainSeller is Subdomain.find_seller_by_hostname's lookup for the label: an all-digit
// label is an external id, else the username with dashes as underscores, among alive users.
func subdomainSeller(ctx context.Context, conn *sql.DB, label string) (*user, error) {
	where, arg := "users.username = ?", []byte(label)
	if isDigits(label) {
		where = "users.external_id = ?"
	} else {
		for i, c := range arg {
			if c == '-' {
				arg[i] = '_'
			}
		}
	}
	u := &user{}
	err := conn.QueryRowContext(ctx, "SELECT "+userColumns+" FROM users WHERE users.deleted_at IS NULL AND "+where+" LIMIT 1",
		string(arg)).Scan(u.dest()...)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return u, err
}

func isDigits(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return s != ""
}

// customDomainRow is the custom domain CustomDomain.find_by_host finds, and what it points at.
type customDomainRow struct {
	userID, productID sql.NullInt64
}

// findCustomDomain is CustomDomain.find_by_host: the apex's row, else www's. find_by takes no
// order, so a second row for the name it finds is one Rails could find instead.
func findCustomDomain(ctx context.Context, conn *sql.DB, host string) (*customDomainRow, error) {
	names := customdomain.Names(host)
	if len(names) == 0 {
		return nil, nil
	}
	rows, err := conn.QueryContext(ctx, "SELECT custom_domains.domain, custom_domains.user_id, custom_domains.product_id FROM custom_domains"+
		" WHERE custom_domains.domain IN ("+placeholders(len(names))+") AND custom_domains.deleted_at IS NULL"+
		" ORDER BY custom_domains.domain = ? DESC LIMIT 2", append(stringArgs(names), names[0])...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var found []customDomainRow
	var domains []string
	for rows.Next() {
		var d customDomainRow
		var domain string
		if err := rows.Scan(&domain, &d.userID, &d.productID); err != nil {
			return nil, err
		}
		found, domains = append(found, d), append(domains, domain)
	}
	switch {
	case rows.Err() != nil:
		return nil, rows.Err()
	case len(found) == 0:
		return nil, nil
	case len(found) == 2 && strings.EqualFold(domains[0], domains[1]):
		return nil, fallback("several custom domains for the host")
	}
	return &found[0], nil
}

func stringArgs(values []string) []any {
	args := make([]any, len(values))
	for i, v := range values {
		args[i] = v
	}
	return args
}

// userByID is a belongs_to :user, which no alive scope narrows.
func userByID(ctx context.Context, conn *sql.DB, id int64) (*user, error) {
	u := &user{}
	err := conn.QueryRowContext(ctx, "SELECT "+userColumns+" FROM users WHERE users.id = ? LIMIT 1", id).Scan(u.dest()...)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return u, err
}

// fetchLeniently is Link.fetch_leniently(permalink, user: seller): a live match oldest
// first, then a legacy permalink, then the seller's permalink redirect.
func fetchLeniently(ctx context.Context, conn *sql.DB, permalink string, sellerID int64) (*product, error) {
	queries := []struct {
		sql  string
		args []any
	}{
		{"SELECT " + productColumns + " FROM links WHERE links.user_id = ? AND links.deleted_at IS NULL" +
			" AND (unique_permalink = ? OR custom_permalink = ?) ORDER BY links.created_at ASC, links.id ASC LIMIT 1",
			[]any{sellerID, permalink, permalink}},
		{"SELECT " + productColumns + " FROM links WHERE links.user_id = ? AND links.deleted_at IS NULL" +
			" AND links.id IN (SELECT legacy_permalinks.product_id FROM legacy_permalinks WHERE legacy_permalinks.permalink = ?) LIMIT 1",
			[]any{sellerID, permalink}},
		{"SELECT " + productColumns + " FROM links WHERE links.user_id = ? AND links.deleted_at IS NULL" +
			" AND links.id IN (SELECT product_permalink_redirects.product_id FROM product_permalink_redirects" +
			" WHERE product_permalink_redirects.seller_id = ? AND product_permalink_redirects.permalink = ?) LIMIT 1",
			[]any{sellerID, sellerID, permalink}},
	}
	for _, q := range queries {
		p := &product{}
		err := conn.QueryRowContext(ctx, q.sql, q.args...).Scan(p.dest()...)
		if errors.Is(err, sql.ErrNoRows) {
			continue
		}
		if err != nil {
			return nil, err
		}
		return p, nil
	}
	return nil, nil
}

// productCustomHTML is the custom HTML of the product's root page, which
// render_custom_html_if_present may serve instead of the page.
func productCustomHTML(ctx context.Context, conn *sql.DB, productID int64) (string, error) {
	var html sql.NullString
	err := conn.QueryRowContext(ctx, "SELECT pages.custom_html FROM pages WHERE pages.pageable_type = 'Link'"+
		" AND pages.pageable_id = ? AND pages.slug IS NULL LIMIT 1", productID).Scan(&html)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return html.String, err
}
