package downloads

import (
	"context"
	"database/sql"
	"errors"

	"github.com/antiwork/gumroad/go_web/internal/db"
	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// Purchase::Reviews::COUNTS_REVIEWS_STATES.
var countsReviewStates = map[string]bool{"successful": true, "gift_receiver_purchase_successful": true, "not_charged": true}

// pageData is what the download page's props read beyond check_permissions' rows.
type pageData struct {
	email, purchaseState, streetAddress, jsonData sql.NullString
	createdAt                                     db.NullTime
	priceCents, shippingCents                     sql.NullInt64
	stripePartiallyRefunded                       bool

	productID                                     int64
	productName, uniquePermalink, customPermalink sql.NullString
	productDeleted                                bool
	productFlags                                  int64
	// ownerUsername and ownerExternalID are the product's user's username and external_id
	// columns, and ownerID its id.
	ownerUsername, ownerExternalID sql.NullString
	ownerID                        int64

	sellerFlags int64
	// purchaserName and purchaserUsername are the purchaser's, when there is one.
	purchaserName, purchaserUsername sql.NullString

	thirdPartyAnalytics bool
}

func (d *pageData) productIs(flag int64) bool { return d.productFlags&flag != 0 }

// pageChecks are the rows whose presence leaves the page to Rails, each as an EXISTS over
// purchases.id, in the order their reason is reported.
var pageChecks = []struct{ reason, exists string }{
	{"review", "SELECT 1 FROM product_reviews WHERE product_reviews.purchase_id = purchases.id"},
	{"call", "SELECT 1 FROM calls WHERE calls.purchase_id = purchases.id"},
	{"custom fields", "SELECT 1 FROM purchase_custom_fields WHERE purchase_custom_fields.purchase_id = purchases.id" +
		" AND purchase_custom_fields.custom_field_id IS NOT NULL"},
	{"integration", "SELECT 1 FROM product_integrations WHERE product_integrations.product_id = links.id AND product_integrations.deleted_at IS NULL"},
	{"variant integration", "SELECT 1 FROM base_variant_integrations JOIN base_variants_purchases" +
		" ON base_variants_purchases.base_variant_id = base_variant_integrations.base_variant_id" +
		" WHERE base_variants_purchases.purchase_id = purchases.id AND base_variant_integrations.deleted_at IS NULL"},
}

// loadPageData reads the rows in one query, or returns a fallback for a purchase whose page
// this port leaves to Rails.
func (h *handler) loadPageData(ctx context.Context, p *page) (*pageData, error) {
	pu := p.purchase
	d := &pageData{}
	var partially, productDeleted sql.NullBool
	var ownerID, sellerFlags sql.NullInt64
	var ownerGA, ownerPixel, ownerJSON sql.NullString
	checks := make([]bool, len(pageChecks))
	query := `SELECT purchases.email, purchases.purchase_state, purchases.street_address, purchases.json_data,
		purchases.created_at, purchases.price_cents, purchases.shipping_cents, purchases.stripe_partially_refunded,
		links.id, links.name, links.unique_permalink, links.custom_permalink, links.deleted_at IS NOT NULL, links.flags,
		owner.id, owner.username, owner.external_id, owner.google_analytics_id, owner.facebook_pixel_id, owner.json_data,
		seller.flags, purchaser.name, purchaser.username,
		EXISTS(SELECT 1 FROM third_party_analytics WHERE third_party_analytics.link_id = links.id
			AND third_party_analytics.deleted_at IS NULL AND third_party_analytics.location IN ('receipt', 'all'))
		OR EXISTS(SELECT 1 FROM third_party_analytics WHERE third_party_analytics.user_id = links.user_id
			AND third_party_analytics.link_id IS NULL AND third_party_analytics.deleted_at IS NULL
			AND third_party_analytics.location IN ('receipt', 'all'))`
	dest := []any{&d.email, &d.purchaseState, &d.streetAddress, &d.jsonData, &d.createdAt, &d.priceCents, &d.shippingCents, &partially,
		&d.productID, &d.productName, &d.uniquePermalink, &d.customPermalink, &productDeleted, &d.productFlags,
		&ownerID, &d.ownerUsername, &d.ownerExternalID, &ownerGA, &ownerPixel, &ownerJSON,
		&sellerFlags, &d.purchaserName, &d.purchaserUsername, &d.thirdPartyAnalytics}
	for i, c := range pageChecks {
		query += ", EXISTS(" + c.exists + ")"
		dest = append(dest, &checks[i])
	}
	err := h.c.DB.QueryRowContext(ctx, query+`
		FROM purchases
		JOIN links ON links.id = purchases.link_id
		LEFT JOIN users owner ON owner.id = links.user_id
		LEFT JOIN users seller ON seller.id = purchases.seller_id
		LEFT JOIN users purchaser ON purchaser.id = purchases.purchaser_id
		WHERE purchases.id = ? LIMIT 1`, pu.id).Scan(dest...)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, fallback("purchase product")
	}
	if err != nil {
		return nil, err
	}
	if !ownerID.Valid || !sellerFlags.Valid {
		return nil, fallback("missing user")
	}
	d.ownerID, d.sellerFlags = ownerID.Int64, sellerFlags.Int64
	d.stripePartiallyRefunded, d.productDeleted = partially.Bool, productDeleted.Bool

	switch {
	case pu.subscriptionID != nil:
		return nil, fallback("membership")
	case pu.flags&(purchaseIsGiftSender|purchaseIsBundleProduct|purchaseIsCommissionDeposit|purchaseIsCommissionCompletion) != 0:
		return nil, fallback("gift, bundle or commission purchase")
	case d.productIs(productIsLicensed):
		return nil, fallback("licensed product")
	case d.productIs(productCommunityChatEnabled):
		return nil, fallback("community chat")
	case !rails.Present(d.uniquePermalink.String) && !rails.Present(d.customPermalink.String):
		// short_link_url raises without a permalink.
		return nil, fallback("no permalink")
	case !d.priceCents.Valid:
		// paid? and free_purchase? compare nil.
		return nil, fallback("nil price")
	}
	for i, c := range pageChecks {
		if checks[i] {
			return nil, fallback(c.reason)
		}
	}
	// PurchaseSellerAnalyticsPresenter reads link.analytics_data, the product user's, and
	// only builds props when one id is set; "" counts.
	if ownerGA.Valid || ownerPixel.Valid {
		return nil, fallback("seller analytics")
	}
	if rails.Present(ownerJSON.String) {
		data, err := rails.ParseJSON([]byte(ownerJSON.String))
		hash, ok := data.(*rails.Hash)
		if err != nil || !ok {
			return nil, fallback("seller json_data")
		}
		if rails.Present(hash.Value("tiktok_pixel_id")) {
			return nil, fallback("seller analytics")
		}
	}
	return d, nil
}

// lastContentPageID is purchase.last_content_page_id: json_data's value when present.
func (d *pageData) lastContentPageID() (any, error) {
	if !rails.Present(d.jsonData.String) {
		return nil, nil
	}
	parsed, err := rails.ParseJSON([]byte(d.jsonData.String))
	data, ok := parsed.(*rails.Hash)
	if err != nil || !ok {
		return nil, fallback("purchase json_data")
	}
	if v := data.Value("last_content_page_id"); rails.Present(v) {
		return v, nil
	}
	return nil, nil
}

// hasInvoice is Purchase#has_invoice? without a subscription: !free_purchase?.
func (d *pageData) hasInvoice() bool {
	// nil == 0 is false, so a nil shipping price is a paid purchase.
	return !(d.priceCents.Int64 == 0 && d.shippingCents.Valid && d.shippingCents.Int64 == 0)
}

// allowsReview is Purchase#allows_review? for a purchase without a subscription.
func (d *pageData) allowsReview(pu *purchase) bool {
	state := d.purchaseState.String
	return countsReviewStates[state] &&
		pu.flags&purchaseExcludesProductReview == 0 &&
		!(state == "not_charged" && pu.flags&purchaseIsFreeTrial == 0) &&
		pu.flags&purchaseIsGiftSender == 0 &&
		!pu.stripeRefunded &&
		!(d.stripePartiallyRefunded && pu.flags&purchaseIsBundleProduct != 0) &&
		pu.chargebackDate == nil &&
		(!pu.accessRevoked() || d.priceCents.Int64 > 0) &&
		pu.flags&purchaseIsCommissionCompletion == 0
}

// raterAccountName is Purchase#rater_account_name.
func (d *pageData) raterAccountName(pu *purchase) any {
	if pu.purchaserID == nil || pu.giftReceiver() && rails.Present(d.streetAddress.String) {
		return nil
	}
	if rails.Present(d.purchaserName.String) {
		return d.purchaserName.String
	}
	if rails.Present(d.purchaserUsername.String) {
		return d.purchaserUsername.String
	}
	return nil
}

// ownerUsernameOrExternalID is User#username: the column when present, else external_id.
func (d *pageData) ownerUsernameOrExternalID() string {
	if rails.Present(d.ownerUsername.String) {
		return d.ownerUsername.String
	}
	return d.ownerExternalID.String
}
