package licenses

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/antiwork/gumroad/go_web/internal/db"
)

// purchaseGraph holds every row payload_for_ping_notification and as_json_for_license read for
// one purchase. loadPurchaseGraph follows the Ruby control flow so it only runs the queries Rails
// would; buildPurchaseJSON turns it into the response without touching the database.
type purchaseGraph struct {
	purchase    *purchase
	seller      *user
	product     *product // purchase.link, which need not be the license's product
	productUser *user
	purchaser   *user

	subscription *subscription
	// Purchase#custom_fields, then the subscription's original purchase's when those are empty.
	customFields             []customField
	subscriptionCustomFields []customField

	hasAffiliateCredit bool
	jsonData           map[string]any // parsed only when an affiliate credit needs it
	affiliate          *affiliate
	affiliateUser      *user
	directAffiliate    bool // DirectAffiliate.find_by(id: json_data["direct_affiliate_id"]) exists

	// variant_attributes in the habtm query's order, which Ruby keeps once loaded.
	variants []*baseVariant

	offerCode *offerCode

	// uses_license_key? and Purchase#license's serial.
	licenseKeyPermitted bool
	licenseSerial       sql.NullString

	gift *gift
}

type subscription struct {
	id          int64
	flags       int64
	endedAt     db.NullTime
	cancelledAt db.NullTime
	failedAt    db.NullTime
	recurrence  sql.NullString
	// Subscription#recurrence raises when its payment option, price or plan is missing.
	recurrenceErr error
}

type customField struct {
	name      string
	fieldType string
	value     sql.NullString
}

// rubyValue is PurchaseCustomField#value: booleans are cast, everything else is to_s.
func (f customField) rubyValue() any {
	if f.fieldType == "terms" || f.fieldType == "checkbox" {
		if !f.value.Valid || f.value.String == "" {
			return nil
		}
		switch f.value.String {
		case "0", "f", "F", "false", "FALSE", "off", "OFF":
			return false
		}
		return true
	}
	return f.value.String
}

type affiliate struct {
	id  int64
	typ string
}

type baseVariant struct {
	id        int64
	typ       sql.NullString
	name      sql.NullString
	flags     int64
	customSku sql.NullString
}

func (v *baseVariant) isSku() bool { return v.typ.Valid && v.typ.String == "Sku" }

type offerCode struct {
	code             sql.NullString
	amountCents      sql.NullInt64
	amountPercentage sql.NullInt64
	// purchase_offer_code_discount, which original_offer_code prefers when present.
	discountAmount    sql.NullInt64
	discountIsPercent sql.NullBool
}

// gift is the gifter purchase's price and email; gifterFound is false when that row is gone.
type gift struct {
	gifterFound bool
	priceCents  sql.NullInt64
	email       sql.NullString
}

var errMissingRecord = errors.New("record missing where Rails would raise NoMethodError")

func loadPurchaseGraph(ctx context.Context, s *store, lk *lookup) (*purchaseGraph, error) {
	p := lk.purchase
	g := &purchaseGraph{purchase: p, hasAffiliateCredit: lk.hasAffiliateCredit}
	var err error
	productHasAliveVariants := false
	switch {
	case !p.linkID.Valid:
	case lk.product != nil && p.linkID.Int64 == lk.product.id:
		g.product, productHasAliveVariants = lk.product, lk.productHasAliveVariants
	default:
		if g.product, productHasAliveVariants, err = s.product(ctx, p.linkID.Int64); err != nil {
			return nil, err
		}
	}
	if !p.sellerID.Valid || g.product == nil {
		return g, nil
	}
	users, err := s.users(ctx, p.sellerID, g.product.userID, p.purchaserID)
	if err != nil {
		return nil, err
	}
	g.seller, g.productUser, g.purchaser = users[p.sellerID.Int64], users[g.product.userID.Int64], users[p.purchaserID.Int64]
	if g.seller == nil {
		return g, nil
	}
	if p.subscriptionID.Valid {
		if g.subscription, err = s.subscription(ctx, p.subscriptionID.Int64); err != nil {
			return nil, err
		}
	}
	if p.affiliateID.Valid {
		if g.affiliate, g.affiliateUser, err = s.affiliate(ctx, p.affiliateID.Int64); err != nil {
			return nil, err
		}
	}
	// credits_direct_affiliate? reads json_data first, so a corrupt one raises for any credit.
	if g.hasAffiliateCredit {
		if g.jsonData, err = purchaseJSONData(p); err != nil {
			return nil, err
		}
		id, ok := jsonInt(g.jsonData["direct_affiliate_id"])
		if ok && g.affiliate != nil && g.affiliate.typ == "Collaborator" {
			if g.directAffiliate, err = s.exists(ctx, "SELECT 1 FROM affiliates WHERE affiliates.type = 'DirectAffiliate' AND affiliates.id = ? LIMIT 1", id); err != nil {
				return nil, err
			}
		}
	}
	if g.variants, err = s.variantAttributes(ctx, p.id); err != nil {
		return nil, err
	}
	if p.offerCodeID.Valid {
		if g.offerCode, err = s.offerCode(ctx, p.offerCodeID.Int64, p.id); err != nil {
			return nil, err
		}
	}
	if g.customFields, err = s.customFields(ctx, p.id); err != nil {
		return nil, err
	}

	// subscription.original_purchase, read at most once for custom fields and the license.
	var originalID sql.NullInt64
	originalLoaded := false
	originalPurchaseID := func() (sql.NullInt64, error) {
		if !originalLoaded {
			originalLoaded = true
			err := s.db.QueryRowContext(ctx, fmt.Sprintf(
				"SELECT purchases.id FROM purchases WHERE purchases.subscription_id = ? AND (purchases.flags & %d = %d) AND (purchases.flags & %d = 0) LIMIT 1",
				purchaseIsOriginalSubscriptionPurchase, purchaseIsOriginalSubscriptionPurchase, purchaseIsArchivedOriginalSubscription), g.subscription.id).Scan(&originalID)
			if err != nil && !errors.Is(err, sql.ErrNoRows) {
				return originalID, err
			}
		}
		return originalID, nil
	}
	// A purchase that is its own live original purchase has just shown it has no custom fields.
	ownOriginal := p.is(purchaseIsOriginalSubscriptionPurchase) && !p.is(purchaseIsArchivedOriginalSubscription)
	if len(g.customFields) == 0 && g.subscription != nil && !ownOriginal {
		id, err := originalPurchaseID()
		if err != nil {
			return nil, err
		}
		if id.Valid {
			if g.subscriptionCustomFields, err = s.customFields(ctx, id.Int64); err != nil {
				return nil, err
			}
		}
	}

	if g.product.is(linkIsLicensed) {
		if g.licenseKeyPermitted, err = s.variantContentPermitsLicenseKey(ctx, g.product, productHasAliveVariants, g.variants); err != nil {
			return nil, err
		}
	}
	if g.licenseKeyPermitted {
		// Purchase#license: a recurring charge's is its original purchase's; any other purchase's
		// is the verified license itself, through has_one :license's inverse.
		if g.isRecurringSubscriptionCharge() {
			id, err := originalPurchaseID()
			if err != nil {
				return nil, err
			}
			if !id.Valid {
				return nil, fmt.Errorf("subscription %d: %w (original_purchase)", g.subscription.id, errMissingRecord)
			}
			err = s.db.QueryRowContext(ctx, "SELECT licenses.serial FROM licenses WHERE licenses.purchase_id = ? LIMIT 1", id.Int64).Scan(&g.licenseSerial)
			if err != nil && !errors.Is(err, sql.ErrNoRows) {
				return nil, err
			}
		} else {
			g.licenseSerial = lk.license.serial
		}
	}

	if p.is(purchaseIsGiftReceiverPurchase) {
		if g.gift, err = s.gift(ctx, p); err != nil {
			return nil, err
		}
	}
	return g, nil
}

// isRecurringSubscriptionCharge is Purchase#is_recurring_subscription_charge.
func (g *purchaseGraph) isRecurringSubscriptionCharge() bool {
	p := g.purchase
	return g.subscription != nil && !p.is(purchaseIsOriginalSubscriptionPurchase) && !p.is(purchaseIsGiftReceiverPurchase)
}

// purchaseJSONData is JsonData#json_data, which raises for anything but a Hash.
func purchaseJSONData(p *purchase) (map[string]any, error) {
	if !p.jsonData.Valid {
		return map[string]any{}, nil
	}
	decoded, err := decodeJSON([]byte(p.jsonData.String))
	if err != nil {
		return nil, err
	}
	if decoded == nil {
		return map[string]any{}, nil
	}
	data, ok := decoded.(map[string]any)
	if !ok {
		return nil, fmt.Errorf("purchase %d json_data is not a hash", p.id)
	}
	return data, nil
}

// jsonInt reads an integer the app wrote into json_data.
func jsonInt(v any) (int64, bool) {
	n, ok := v.(json.Number)
	if !ok {
		return 0, false
	}
	i, err := n.Int64()
	return i, err == nil
}

// subscription reads Subscription#recurrence's last_payment_option chain in the same statement.
func (s *store) subscription(ctx context.Context, id int64) (*subscription, error) {
	sub := &subscription{}
	var optionID, priceID, planID sql.NullInt64
	var priceRecurrence, snapshotRecurrence, planRecurrence sql.NullString
	err := s.db.QueryRowContext(ctx, `SELECT subscriptions.id, subscriptions.flags, subscriptions.ended_at,
		subscriptions.cancelled_at, subscriptions.failed_at, payment_options.id, payment_options.price_id,
		payment_options.product_installment_plan_id, prices.recurrence, installment_plan_snapshots.recurrence,
		product_installment_plans.recurrence
		FROM subscriptions
		LEFT JOIN payment_options ON payment_options.id = subscriptions.last_payment_option_id
		LEFT JOIN prices ON prices.id = payment_options.price_id
		LEFT JOIN installment_plan_snapshots ON installment_plan_snapshots.payment_option_id = payment_options.id
		LEFT JOIN product_installment_plans ON product_installment_plans.id = payment_options.product_installment_plan_id
		WHERE subscriptions.id = ? LIMIT 1`, id).Scan(&sub.id, &sub.flags, &sub.endedAt, &sub.cancelledAt, &sub.failedAt,
		&optionID, &priceID, &planID, &priceRecurrence, &snapshotRecurrence, &planRecurrence)
	if sub, err = found(sub, err); sub == nil || err != nil {
		return sub, err
	}
	switch {
	case sub.flags&subscriptionIsInstallmentPlan != 0:
		// The snapshot, else the plan, of last_payment_option itself.
		switch {
		case !optionID.Valid:
			sub.recurrenceErr = errMissingRecord
		case snapshotRecurrence.Valid:
			sub.recurrence = snapshotRecurrence
		case planID.Valid && planRecurrence.Valid:
			sub.recurrence = planRecurrence
		default:
			sub.recurrenceErr = errMissingRecord
		}
	case optionID.Valid:
		sub.recurrence, sub.recurrenceErr = priceRecurrenceOrErr(priceID, priceRecurrence)
	default:
		// last_payment_option || payment_options.alive.last
		err := s.db.QueryRowContext(ctx, `SELECT payment_options.price_id, prices.recurrence FROM payment_options
			LEFT JOIN prices ON prices.id = payment_options.price_id
			WHERE payment_options.subscription_id = ? AND payment_options.deleted_at IS NULL
			ORDER BY payment_options.id DESC LIMIT 1`, sub.id).Scan(&priceID, &priceRecurrence)
		switch {
		case errors.Is(err, sql.ErrNoRows):
			sub.recurrenceErr = errMissingRecord
		case err != nil:
			return nil, err
		default:
			sub.recurrence, sub.recurrenceErr = priceRecurrenceOrErr(priceID, priceRecurrence)
		}
	}
	return sub, nil
}

// priceRecurrenceOrErr is payment_option.price.recurrence; a missing price raises.
func priceRecurrenceOrErr(priceID sql.NullInt64, recurrence sql.NullString) (sql.NullString, error) {
	if !priceID.Valid {
		return sql.NullString{}, errMissingRecord
	}
	return recurrence, nil
}

// affiliate is purchase.affiliate with its affiliate_user.
func (s *store) affiliate(ctx context.Context, id int64) (*affiliate, *user, error) {
	a := &affiliate{}
	var u user
	var userID sql.NullInt64
	err := s.db.QueryRowContext(ctx, `SELECT affiliates.id, affiliates.type, users.id, users.external_id, users.username,
		users.email, users.unconfirmed_email FROM affiliates LEFT JOIN users ON users.id = affiliates.affiliate_user_id
		WHERE affiliates.id = ? LIMIT 1`, id).Scan(&a.id, &a.typ, &userID, &u.externalID, &u.username, &u.email, &u.unconfirmedEmail)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil, nil
	}
	if err != nil || !userID.Valid {
		return a, nil, err
	}
	u.id = userID.Int64
	return a, &u, nil
}

func (s *store) customFields(ctx context.Context, purchaseID int64) ([]customField, error) {
	rows, err := s.db.QueryContext(ctx, "SELECT name, field_type, value FROM purchase_custom_fields WHERE purchase_custom_fields.purchase_id = ?", purchaseID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var fields []customField
	for rows.Next() {
		var f customField
		if err := rows.Scan(&f.name, &f.fieldType, &f.value); err != nil {
			return nil, err
		}
		fields = append(fields, f)
	}
	return fields, rows.Err()
}

// variantAttributes is the habtm query, whose unordered result Ruby keeps for every later read.
func (s *store) variantAttributes(ctx context.Context, purchaseID int64) ([]*baseVariant, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT base_variants.id, base_variants.type, base_variants.name, base_variants.flags,
		base_variants.custom_sku FROM base_variants
		INNER JOIN base_variants_purchases ON base_variants.id = base_variants_purchases.base_variant_id
		WHERE base_variants_purchases.purchase_id = ?`, purchaseID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var variants []*baseVariant
	for rows.Next() {
		v := &baseVariant{}
		if err := rows.Scan(&v.id, &v.typ, &v.name, &v.flags, &v.customSku); err != nil {
			return nil, err
		}
		variants = append(variants, v)
	}
	return variants, rows.Err()
}

// offerCode is purchase.offer_code with purchase_offer_code_discount alongside.
func (s *store) offerCode(ctx context.Context, id, purchaseID int64) (*offerCode, error) {
	o := &offerCode{}
	err := s.db.QueryRowContext(ctx, `SELECT offer_codes.code, offer_codes.amount_cents, offer_codes.amount_percentage,
		purchase_offer_code_discounts.offer_code_amount, purchase_offer_code_discounts.offer_code_is_percent
		FROM offer_codes LEFT JOIN purchase_offer_code_discounts ON purchase_offer_code_discounts.purchase_id = ?
		WHERE offer_codes.id = ? LIMIT 1`, purchaseID, id).Scan(&o.code, &o.amountCents, &o.amountPercentage, &o.discountAmount, &o.discountIsPercent)
	return found(o, err)
}

// gift is Purchase#gift's gifter_purchase; Purchase#gift prefers the sender side.
func (s *store) gift(ctx context.Context, p *purchase) (*gift, error) {
	column := "giftee_purchase_id"
	if p.is(purchaseIsGiftSenderPurchase) {
		column = "gifter_purchase_id"
	}
	g := &gift{}
	var gifterID sql.NullInt64
	err := s.db.QueryRowContext(ctx, `SELECT gifters.id, gifters.price_cents, gifters.email FROM gifts
		LEFT JOIN purchases gifters ON gifters.id = gifts.gifter_purchase_id WHERE gifts.`+column+` = ? LIMIT 1`, p.id).
		Scan(&gifterID, &g.priceCents, &g.email)
	g.gifterFound = gifterID.Valid
	return found(g, err)
}

const (
	contentProduct   = "product"
	contentAlive     = "alive"
	contentPurchased = "purchased"
)

// variantContentPermitsLicenseKey is Purchase#variant_content_permits_license_key?, with
// has_product_level_rich_content?'s pages and the purchased variants' read in one statement.
func (s *store) variantContentPermitsLicenseKey(ctx context.Context, link *product, hasAliveVariants bool, variants []*baseVariant) (bool, error) {
	if link.is(linkIsPhysical) || !hasAliveVariants {
		return true, nil
	}
	sharesContent := link.is(linkHasSameRichContentForVariant)
	var branches []string
	var args []any
	if sharesContent {
		branches = append(branches,
			`SELECT 'product', rich_contents.title, rich_contents.description FROM rich_contents
			WHERE rich_contents.entity_id = ? AND rich_contents.entity_type = 'Link' AND rich_contents.deleted_at IS NULL`,
			`SELECT 'alive', rich_contents.title, rich_contents.description FROM rich_contents
			INNER JOIN base_variants ON base_variants.id = rich_contents.entity_id
			INNER JOIN variant_categories ON variant_categories.id = base_variants.variant_category_id
			WHERE rich_contents.entity_type = 'BaseVariant' AND rich_contents.deleted_at IS NULL
			AND base_variants.type = 'Variant' AND base_variants.deleted_at IS NULL
			AND variant_categories.link_id = ? AND variant_categories.deleted_at IS NULL`)
		args = append(args, link.id, link.id)
	}
	if len(variants) > 0 {
		branches = append(branches, `SELECT 'purchased', rich_contents.title, rich_contents.description FROM rich_contents
			WHERE rich_contents.entity_type = 'BaseVariant' AND rich_contents.deleted_at IS NULL
			AND rich_contents.entity_id IN (?`+strings.Repeat(", ?", len(variants)-1)+`)`)
		for _, v := range variants {
			args = append(args, v.id)
		}
	}
	if len(branches) == 0 {
		return true, nil
	}
	contents, err := s.richContents(ctx, strings.Join(branches, " UNION ALL "), args...)
	if err != nil {
		return false, err
	}
	if sharesContent && !recoverableHiddenVariantRichContent(contents) {
		return true, nil
	}
	purchased := false
	for _, c := range contents {
		if c.set == contentPurchased {
			purchased = true
			if c.hasLicenseKey() {
				return true, nil
			}
		}
	}
	return !purchased, nil
}

// recoverableHiddenVariantRichContent is Link#recoverable_hidden_variant_rich_content? for a
// product that shares content across variants and is not physical.
func recoverableHiddenVariantRichContent(contents []*richContent) bool {
	for _, c := range contents {
		if c.set == contentProduct && c.hasEditorContent() {
			return false
		}
	}
	for _, c := range contents {
		if c.set == contentAlive && c.hasEditorContent() {
			return true
		}
	}
	return false
}

func (s *store) richContents(ctx context.Context, query string, args ...any) ([]*richContent, error) {
	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var contents []*richContent
	for rows.Next() {
		c := &richContent{}
		if err := rows.Scan(&c.set, &c.Title, &c.DescriptionJSON); err != nil {
			return nil, err
		}
		contents = append(contents, c)
	}
	return contents, rows.Err()
}
