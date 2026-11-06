package licenses

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/db"
	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// flag_shih_tzu masks: flag n is 1 << (n-1), per each model's has_flags.
const (
	linkIsRecurringBilling           = 1 << 1
	linkIsLicensed                   = 1 << 6
	linkIsPhysical                   = 1 << 7
	linkSkusEnabled                  = 1 << 8
	linkHasSameRichContentForVariant = 1 << 24

	purchaseIsOriginalSubscriptionPurchase = 1 << 2
	purchaseIsPreorderAuthorization        = 1 << 3
	purchaseIsGiftReceiverPurchase         = 1 << 5
	purchaseIsGiftSenderPurchase           = 1 << 6
	purchaseChargebackReversed             = 1 << 9
	purchaseWasDiscoverFeeCharged          = 1 << 15
	purchaseIsArchivedOriginalSubscription = 1 << 17
	purchaseIsMultiseatLicense             = 1 << 21
	purchaseIsAccessRevoked                = 1 << 24

	baseVariantIsDefaultSku = 1 << 0

	subscriptionIsInstallmentPlan = 1 << 6

	userHasUsedCLI = 1 << 29
)

type license struct {
	id                 int64
	linkID             sql.NullInt64
	purchaseID         sql.NullInt64
	importedCustomerID sql.NullInt64
	serial             sql.NullString
	uses               sql.NullInt64
	disabledAt         db.NullTime
}

type product struct {
	id                int64
	userID            sql.NullInt64
	name              string
	uniquePermalink   sql.NullString
	customPermalink   sql.NullString
	priceCurrencyType sql.NullString
	requireShipping   sql.NullBool
	flags             int64
	createdAt         db.NullTime
}

func (p *product) is(mask int64) bool { return p.flags&mask != 0 }

type purchase struct {
	id                   int64
	sellerID             sql.NullInt64
	linkID               sql.NullInt64
	createdAt            db.NullTime
	feeCents             sql.NullInt64
	email                sql.NullString
	priceCents           sql.NullInt64
	streetAddress        sql.NullString
	city                 sql.NullString
	state                sql.NullString
	zipCode              sql.NullString
	country              sql.NullString
	fullName             sql.NullString
	purchaserID          sql.NullInt64
	stripeRefunded       sql.NullBool
	canContact           sql.NullBool
	referrer             sql.NullString
	chargebackDate       db.NullTime
	cardType             sql.NullString
	cardVisual           sql.NullString
	ipCountry            sql.NullString
	flags                int64
	offerCodeID          sql.NullInt64
	subscriptionID       sql.NullInt64
	affiliateCreditCents sql.NullInt64
	jsonData             sql.NullString
	quantity             int64
	shippingCents        sql.NullInt64
	affiliateID          sql.NullInt64
}

func (p *purchase) is(mask int64) bool { return p.flags&mask != 0 }

type user struct {
	id                             int64
	externalID                     sql.NullString
	username                       sql.NullString
	email                          sql.NullString
	unconfirmedEmail               sql.NullString
	flags                          int64
	deletedAt                      db.NullTime
	lastActiveSessionsInvalidateAt db.NullTime
}

// formEmail is User#form_email.
func (u *user) formEmail() any {
	if presentString(u.unconfirmedEmail) {
		return u.unconfirmedEmail.String
	}
	if presentString(u.email) {
		return u.email.String
	}
	return nil
}

type store struct {
	db *sql.DB
}

const (
	productColumns = "links.id, links.user_id, links.name, links.unique_permalink, links.custom_permalink, " +
		"links.price_currency_type, links.require_shipping, links.flags, links.created_at"
	purchaseColumns = "purchases.id, purchases.seller_id, purchases.link_id, purchases.created_at, purchases.fee_cents, " +
		"purchases.email, purchases.price_cents, purchases.street_address, purchases.city, purchases.state, purchases.zip_code, " +
		"purchases.country, purchases.full_name, purchases.purchaser_id, purchases.stripe_refunded, purchases.can_contact, " +
		"purchases.referrer, purchases.chargeback_date, purchases.card_type, purchases.card_visual, purchases.ip_country, " +
		"purchases.flags, purchases.offer_code_id, purchases.subscription_id, purchases.affiliate_credit_cents, " +
		"purchases.json_data, purchases.quantity, purchases.shipping_cents, purchases.affiliate_id"
	userColumns = "users.id, users.external_id, users.username, users.email, users.unconfirmed_email, users.flags, " +
		"users.deleted_at, users.last_active_sessions_invalidated_at"

	// Link#alive_variants for the product in the outer query.
	aliveVariantsOfLink = `SELECT base_variants.id FROM base_variants INNER JOIN variant_categories
		ON base_variants.variant_category_id = variant_categories.id WHERE base_variants.type = 'Variant'
		AND base_variants.deleted_at IS NULL AND variant_categories.deleted_at IS NULL AND variant_categories.link_id = `
)

// productScan and purchaseScan take LEFT JOINed columns, which are all NULL for a missing row.
type productScan struct {
	id, flags sql.NullInt64
	name      sql.NullString
	p         product
}

func (s *productScan) dest() []any {
	return []any{&s.id, &s.p.userID, &s.name, &s.p.uniquePermalink, &s.p.customPermalink, &s.p.priceCurrencyType,
		&s.p.requireShipping, &s.flags, &s.p.createdAt}
}

func (s *productScan) row() *product {
	if !s.id.Valid {
		return nil
	}
	s.p.id, s.p.name, s.p.flags = s.id.Int64, s.name.String, s.flags.Int64
	return &s.p
}

type purchaseScan struct {
	id, flags, quantity sql.NullInt64
	p                   purchase
}

func (s *purchaseScan) dest() []any {
	p := &s.p
	return []any{&s.id, &p.sellerID, &p.linkID, &p.createdAt, &p.feeCents, &p.email, &p.priceCents, &p.streetAddress,
		&p.city, &p.state, &p.zipCode, &p.country, &p.fullName, &p.purchaserID, &p.stripeRefunded, &p.canContact,
		&p.referrer, &p.chargebackDate, &p.cardType, &p.cardVisual, &p.ipCountry, &s.flags, &p.offerCodeID,
		&p.subscriptionID, &p.affiliateCreditCents, &p.jsonData, &s.quantity, &p.shippingCents, &p.affiliateID}
}

func (s *purchaseScan) row() *purchase {
	if !s.id.Valid {
		return nil
	}
	s.p.id, s.p.flags, s.p.quantity = s.id.Int64, s.flags.Int64, s.quantity.Int64
	return &s.p
}

// lookup is everything fetch_valid_license and the response read through the license.
type lookup struct {
	license *license
	product *product // license.link
	// The product is licensed and has alive variants, for has_product_level_rich_content?.
	productHasAliveVariants bool
	purchase                *purchase // license.purchase
	// purchase.affiliate_credit.present?
	hasAffiliateCredit bool
}

var lookupQuery = fmt.Sprintf(`SELECT licenses.id, licenses.link_id, licenses.purchase_id, licenses.imported_customer_id,
	licenses.serial, licenses.uses, licenses.disabled_at, %s,
	(links.flags & %d) != 0 AND EXISTS (%s links.id), %s,
	EXISTS (SELECT 1 FROM affiliate_credits WHERE affiliate_credits.purchase_id = purchases.id
		AND affiliate_credits.is_direct_affiliate_credit = FALSE)
	FROM licenses LEFT JOIN links ON links.id = licenses.link_id
	LEFT JOIN purchases ON purchases.id = licenses.purchase_id WHERE `,
	productColumns, linkIsLicensed, aliveVariantsOfLink, purchaseColumns)

// findLicense is License.find_by(serial:), or product.licenses.find_by(serial:) when
// productID is set, with the product and purchase those reads go on to load. A blank key
// matches no license whichever way ActiveRecord would bind it, so it is bound as NULL.
func (s *store) findLicense(ctx context.Context, productID *int64, licenseKey any) (*lookup, error) {
	where, args := "licenses.serial IS NULL", []any{}
	if key, ok := licenseKey.(string); ok && rails.Present(key) {
		where, args = "licenses.serial = ?", []any{key}
	}
	if productID != nil {
		where, args = "licenses.link_id = ? AND "+where, append([]any{*productID}, args...)
	}
	l := &license{}
	var prod productScan
	var purch purchaseScan
	var aliveVariants sql.NullBool
	lk := &lookup{license: l}
	dest := append([]any{&l.id, &l.linkID, &l.purchaseID, &l.importedCustomerID, &l.serial, &l.uses, &l.disabledAt}, prod.dest()...)
	dest = append(append(append(dest, &aliveVariants), purch.dest()...), &lk.hasAffiliateCredit)
	err := s.db.QueryRowContext(ctx, lookupQuery+where+" LIMIT 1", args...).Scan(dest...)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	lk.product, lk.purchase, lk.productHasAliveVariants = prod.row(), purch.row(), aliveVariants.Bool
	// product.licenses.find_by never sees a license whose product row is gone.
	if productID != nil && lk.product == nil {
		return nil, nil
	}
	return lk, nil
}

func (s *store) product(ctx context.Context, id int64) (*product, bool, error) {
	var prod productScan
	var aliveVariants sql.NullBool
	err := s.db.QueryRowContext(ctx, fmt.Sprintf("SELECT %s, (links.flags & %d) != 0 AND EXISTS (%s links.id) FROM links WHERE links.id = ? LIMIT 1",
		productColumns, linkIsLicensed, aliveVariantsOfLink), id).Scan(append(prod.dest(), &aliveVariants)...)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, false, nil
	}
	return prod.row(), aliveVariants.Bool, err
}

func scanUser(scan func(...any) error) (*user, error) {
	u := &user{}
	err := scan(&u.id, &u.externalID, &u.username, &u.email, &u.unconfirmedEmail, &u.flags, &u.deletedAt, &u.lastActiveSessionsInvalidateAt)
	return u, err
}

func (s *store) user(ctx context.Context, id int64) (*user, error) {
	return found(scanUser(s.db.QueryRowContext(ctx, "SELECT "+userColumns+" FROM users WHERE users.id = ? LIMIT 1", id).Scan))
}

// users loads each distinct id once; a missing row is absent from the map, as belongs_to gives nil.
func (s *store) users(ctx context.Context, ids ...sql.NullInt64) (map[int64]*user, error) {
	byID := map[int64]*user{}
	var args []any
	for _, id := range ids {
		if _, seen := byID[id.Int64]; id.Valid && !seen {
			byID[id.Int64] = nil
			args = append(args, id.Int64)
		}
	}
	if len(args) == 0 {
		return byID, nil
	}
	rows, err := s.db.QueryContext(ctx, "SELECT "+userColumns+" FROM users WHERE users.id IN (?"+strings.Repeat(", ?", len(args)-1)+")", args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		u, err := scanUser(rows.Scan)
		if err != nil {
			return nil, err
		}
		byID[u.id] = u
	}
	return byID, rows.Err()
}

// incrementUses is increment!(:uses)'s update_counters: no callbacks, no updated_at.
func (s *store) incrementUses(ctx context.Context, licenseID int64) error {
	_, err := s.db.ExecContext(ctx, "UPDATE licenses SET licenses.uses = COALESCE(licenses.uses, 0) + ? WHERE licenses.id = ?", 1, licenseID)
	return err
}

// markCLIUser is Api::V2::BaseController#mark_cli_user's update_all.
func (s *store) markCLIUser(ctx context.Context, userID int64) error {
	_, err := s.db.ExecContext(ctx, "UPDATE users SET flags = flags | ? WHERE users.id = ? AND (flags & ? = 0)", userHasUsedCLI, userID, userHasUsedCLI)
	return err
}

type importedCustomer struct {
	id           int64
	email        sql.NullString
	purchaseDate db.NullTime
	createdAt    time.Time
	linkName     sql.NullString // imported_customer.link&.name
}

func (s *store) importedCustomer(ctx context.Context, id int64) (*importedCustomer, error) {
	c := &importedCustomer{}
	err := s.db.QueryRowContext(ctx, `SELECT imported_customers.id, imported_customers.email, imported_customers.purchase_date,
		imported_customers.created_at, links.name FROM imported_customers LEFT JOIN links ON links.id = imported_customers.link_id
		WHERE imported_customers.id = ? LIMIT 1`, id).Scan(&c.id, &c.email, &c.purchaseDate, &c.createdAt, &c.linkName)
	return found(c, err)
}

func (s *store) exists(ctx context.Context, query string, args ...any) (bool, error) {
	var one int
	err := s.db.QueryRowContext(ctx, query, args...).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

func found[T any](v *T, err error) (*T, error) {
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return v, nil
}

func presentString(s sql.NullString) bool { return s.Valid && rails.Present(s.String) }

func nullString(s sql.NullString) any {
	if !s.Valid {
		return nil
	}
	return s.String
}

func nullInt(n sql.NullInt64) any {
	if !n.Valid {
		return nil
	}
	return n.Int64
}

func decodeJSON(data []byte) (any, error) {
	if len(strings.TrimSpace(string(data))) == 0 {
		return nil, nil
	}
	decoder := json.NewDecoder(strings.NewReader(string(data)))
	decoder.UseNumber()
	var v any
	err := decoder.Decode(&v)
	return v, err
}
