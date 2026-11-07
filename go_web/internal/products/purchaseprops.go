package products

import (
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/db"
	"github.com/antiwork/gumroad/go_web/internal/rails"
)

const (
	urlRedirectIsDonePDFStamping int64 = 1 << 3
	productFilePDFStampEnabled   int64 = 1 << 4
)

// allSuccessStates is Purchase::ALL_SUCCESS_STATES.
var allSuccessStates = map[string]bool{"preorder_authorization_successful": true, "successful": true,
	"not_charged": true, "gift_receiver_purchase_successful": true}

// recurrenceLongIndicators are BasePrice::Recurrence#recurrence_long_indicator's.
var recurrenceLongIndicators = map[string]string{"monthly": "a month", "quarterly": "every 3 months",
	"biannually": "every 6 months", "yearly": "a year", "every_two_years": "every 2 years"}

// visitorPurchase is the purchases row purchase_info reads.
type visitorPurchase struct {
	id, flags                                         int64
	purchaserID, offerCodeID, subscriptionID, priceID sql.NullInt64
	sellerID, zipTaxRateID, priceCents                sql.NullInt64
	totalTransactionCents, shippingCents              sql.NullInt64
	taxCents, gumroadTaxCents                         sql.NullInt64
	email, currency, rate, state, streetAddress       sql.NullString
	stripeRefunded, rentalExpired, webhookFailed      sql.NullBool
	createdAt, chargebackDate                         db.NullTime
}

const visitorPurchaseColumns = `purchases.id, purchases.flags, purchases.price_cents, purchases.purchaser_id,
	purchases.offer_code_id, purchases.subscription_id, purchases.price_id, purchases.total_transaction_cents,
	purchases.email, purchases.displayed_price_currency_type, purchases.rate_converted_to_usd, purchases.purchase_state,
	purchases.street_address, purchases.stripe_refunded, purchases.rental_expired, purchases.webhook_failed,
	purchases.created_at, purchases.chargeback_date, purchases.seller_id, purchases.zip_tax_rate_id,
	purchases.shipping_cents, purchases.tax_cents, purchases.gumroad_tax_cents`

func (vp *visitorPurchase) dest() []any {
	return []any{&vp.id, &vp.flags, &vp.priceCents, &vp.purchaserID, &vp.offerCodeID, &vp.subscriptionID, &vp.priceID,
		&vp.totalTransactionCents, &vp.email, &vp.currency, &vp.rate, &vp.state, &vp.streetAddress, &vp.stripeRefunded,
		&vp.rentalExpired, &vp.webhookFailed, &vp.createdAt, &vp.chargebackDate, &vp.sellerID, &vp.zipTaxRateID,
		&vp.shippingCents, &vp.taxCents, &vp.gumroadTaxCents}
}

// purchaseProps is ProductProps#purchase_props of Link#purchase_info_for_product_page: a review
// link's purchase, else the signed-in visitor's own, else one this browser made signed out.
func (h *handler) purchaseProps(p *page, prod *product, v *view) (any, error) {
	// The review link's purchase id and email digest identify the visitor, so its purchase keeps
	// its license key and skips the expired-rental check.
	if p.reviewPurchase != nil {
		return h.purchaseInfoProps(p, prod, v, p.reviewPurchase, true)
	}
	guid, hasGUID := p.Req.Cookie(guidCookie)
	hasGUID = hasGUID && !p.MintedGUID
	if p.viewer != nil {
		vp, err := h.lastEligiblePurchase(p, prod, "index_purchases_on_purchaser_id",
			"purchases.purchaser_id = ? AND purchases.link_id = ?", p.viewer.id, prod.id)
		if err != nil || vp != nil {
			return h.shownPurchase(p, prod, v, vp, true, err)
		}
		if !hasGUID {
			return nil, nil
		}
		// A purchase of theirs in any state keeps the browser's out.
		bought, err := h.exists(p.Ctx, "SELECT 1 FROM purchases WHERE purchases.purchaser_id = ? AND purchases.link_id = ? LIMIT 1",
			p.viewer.id, prod.id)
		if err != nil || bought {
			return nil, err
		}
	}
	if !hasGUID {
		return nil, nil
	}
	vp, err := h.lastEligiblePurchase(p, prod, "index_purchases_on_browser_guid", "purchases.link_id = ? AND (purchases.flags & ?) = 0"+
		" AND purchases.browser_guid = ? AND purchases.purchaser_id IS NULL", prod.id, purchaseIsGiftReceiver, guid)
	return h.shownPurchase(p, prod, v, vp, false, err)
}

// reviewCountedPurchases is Purchase.allowing_reviews_to_be_counted, as production renders it.
var reviewCountedPurchases = fmt.Sprintf("purchases.purchase_state IN ('successful', 'gift_receiver_purchase_successful', 'not_charged')"+
	" AND (purchases.purchase_state != 'not_charged' OR purchases.flags & %d != 0)"+
	" AND (purchases.stripe_refunded IS NULL OR purchases.stripe_refunded = 0)"+
	" AND (purchases.stripe_partially_refunded IS NULL OR purchases.stripe_partially_refunded = false OR (purchases.flags & %d = 0))"+
	" AND (purchases.chargeback_date IS NULL) AND %s AND (purchases.flags & %d = 0) AND (purchases.flags & %d = 0)"+
	" AND ((purchases.flags & %d = 0) OR purchases.purchase_state = 'successful' AND (purchases.price_cents > 0)"+
	" AND (stripe_refunded IS NULL OR stripe_refunded = 0)) AND (purchases.flags & %d = 0)",
	purchaseIsFreeTrial, purchaseIsBundleProduct, notRecurringCharge, purchaseIsGiftSender, purchaseExcludesProductReview,
	purchaseIsAccessRevoked, purchaseIsCommissionCompletion)

// digestPurchase is purchase_for_email_digest: the product's review-counting sale that
// params[:purchase_id] names, when params[:purchase_email_digest] is its email_digest.
func (h *handler) digestPurchase(p *page, prod *product) (*visitorPurchase, error) {
	external, _ := p.Req.Param("purchase_id").(string)
	digest, _ := p.Req.Param("purchase_email_digest").(string)
	if rails.Blank(external) || rails.Blank(digest) {
		return nil, nil
	}
	id, ok := h.c.IDs.Decrypt(external)
	if !ok {
		return nil, nil
	}
	vp := &visitorPurchase{}
	err := h.c.DB.QueryRowContext(p.Ctx, "SELECT "+visitorPurchaseColumns+" FROM purchases WHERE purchases.link_id = ? AND "+
		reviewCountedPurchases+" AND purchases.id = ? LIMIT 1", prod.id, id).Scan(vp.dest()...)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if want, _ := rails.EmailDigest(h.c.Page.EmailDigestKey, vp.id, vp.email.String).(string); !rails.SecureCompare(want, digest) {
		return nil, nil
	}
	return vp, nil
}

// lastEligiblePurchase is the eligible purchases' last, nil without one. The index is the one
// MySQL takes for Rails' statement; ORDER BY id alone could tempt it into a primary key scan.
func (h *handler) lastEligiblePurchase(p *page, prod *product, index, where string, args ...any) (*visitorPurchase, error) {
	if prod.is(productIsInPreorderState) {
		where += " AND purchases.purchase_state IN ('preorder_authorization_successful', 'gift_receiver_purchase_successful')"
	} else {
		where += " AND purchases.purchase_state IN ('successful', 'gift_receiver_purchase_successful')" +
			" AND (purchases.stripe_refunded IS NULL OR purchases.stripe_refunded = 0) AND purchases.chargeback_date IS NULL" +
			" AND (purchases.flags & ?) = 0"
		args = append(args, purchaseIsAdditionalContribution)
	}
	vp := &visitorPurchase{}
	err := h.c.DB.QueryRowContext(p.Ctx, "SELECT "+visitorPurchaseColumns+" FROM purchases FORCE INDEX ("+index+") WHERE "+where+
		" AND (purchases.flags & ?) = 0 ORDER BY purchases.id DESC LIMIT 1", append(args, purchaseIsGiftSender)...).Scan(vp.dest()...)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return vp, err
}

// shownPurchase is purchase_info_for_product_page's answer for the purchase found: none for a
// rental that expired.
func (h *handler) shownPurchase(p *page, prod *product, v *view, vp *visitorPurchase, signedIn bool, err error) (any, error) {
	if err != nil || vp == nil || vp.rentalExpired.Bool {
		return nil, err
	}
	return h.purchaseInfoProps(p, prod, v, vp, signedIn)
}

// purchaseInfoProps is purchase_props of Purchase#purchase_info, for the shapes this port reads.
func (h *handler) purchaseInfoProps(p *page, prod *product, v *view, vp *visitorPurchase, signedIn bool) (any, error) {
	ctx := p.Ctx
	switch {
	case vp.flags&(purchaseIsGiftReceiver|purchaseIsGiftSender) != 0:
		return nil, fallback("gift purchase")
	case prod.is(productIsPhysical):
		return nil, fallback("physical purchase")
	}
	// The presentment's own formatting, the shipment's tracking URL and the variant-scoped
	// license key aren't ported.
	unported, err := h.exists(ctx, "SELECT 1 FROM purchases WHERE purchases.id = ? AND (EXISTS(SELECT 1 FROM purchase_presentments"+
		" WHERE purchase_presentments.purchase_id = purchases.id) OR EXISTS(SELECT 1 FROM shipments WHERE shipments.purchase_id = purchases.id))",
		vp.id)
	if err != nil || unported {
		return nil, firstErr(err, fallback("purchase presentment or shipment"))
	}
	if err := h.purchaseInfoRaises(p, prod, vp); err != nil {
		return nil, err
	}
	if signedIn && prod.is(productIsLicensed) {
		licensed, err := h.exists(ctx, "SELECT 1 FROM licenses WHERE licenses.purchase_id = ? LIMIT 1", vp.id)
		if err != nil || licensed {
			return nil, firstErr(err, fallback("purchase license key"))
		}
	}

	sub, err := h.purchaseSubscription(p, vp)
	if err != nil {
		return nil, err
	}
	total, err := h.formattedTotal(p, vp, sub)
	if err != nil {
		return nil, err
	}
	review, err := h.purchaseReview(p, vp, sub)
	if err != nil {
		return nil, err
	}
	accountName, err := h.raterAccountName(p, vp)
	if err != nil {
		return nil, err
	}
	var token sql.NullString
	var redirectFlags int64
	// The has_one's statement, verbatim: it has no ORDER BY, so MySQL's plan picks the row.
	found := false
	if err := scanNamed(ctx, h.c.DB, func(cols map[string]any) func() {
		cols["token"], cols["flags"] = &token, &redirectFlags
		return func() { found = true }
	}, "SELECT `url_redirects`.* FROM `url_redirects` WHERE `url_redirects`.`purchase_id` = ? LIMIT 1", vp.id); err != nil {
		return nil, err
	}
	hasContent := found && !vp.webhookFailed.Bool && !(hasStampablePDFs(v.files) && redirectFlags&urlRedirectIsDonePDFStamping == 0)
	var contentURL any
	if hasContent {
		contentURL = h.c.Env.Protocol + "://" + h.c.Env.Domain + "/d/" + token.String
	}
	var membership any
	if prod.is(productIsTieredMembership) {
		if membership, err = h.purchaseMembership(p, prod, vp, sub); err != nil {
			return nil, err
		}
	}
	testPurchase := vp.purchaserID.Valid && vp.purchaserID.Int64 == prod.userID
	return rails.NewRHash().
		Sym("id", h.c.IDs.Encrypt(vp.id)).
		Sym("email_digest", rails.EmailDigest(h.c.Page.EmailDigestKey, vp.id, vp.email.String)).
		Sym("created_at", vp.createdAt.OrNil()).
		Sym("review", review).
		Sym("review_account_name", accountName).
		Sym("should_show_receipt", !testPurchase && !vp.stripeRefunded.Bool && !vp.chargebackDate.Valid && allSuccessStates[vp.state.String]).
		Sym("was_paid", vp.priceCents.Int64 > 0 || vp.offerCodeID.Valid).
		Sym("is_gift_receiver_purchase", false).
		Sym("show_view_content_button_on_product_page", prod.is(productIsTieredMembership) && found || hasContent).
		Sym("total_price_including_tax_and_shipping", total).
		Sym("content_url", contentURL).
		Sym("subscription_has_lapsed", prod.is(productIsRecurringBilling) && !sub.alive(p.Req.Now)).
		Sym("membership", membership).
		Sym("license_key", nil), nil
}

// purchaseInfoRaises goes to Rails where Purchase.purchase_info raises building keys the page
// never reads: comparing a NULL amount, the seller is_following? reads, a live rate the
// product's currency would need, or a VAT label's missing rate.
func (h *handler) purchaseInfoRaises(p *page, prod *product, vp *visitorPurchase) error {
	taxable := vp.flags&purchaseWasTaxable != 0
	switch {
	case !vp.priceCents.Valid || !vp.shippingCents.Valid || !vp.taxCents.Valid || !taxable && !vp.gumroadTaxCents.Valid:
		return fallback("purchase amounts")
	case !vp.sellerID.Valid || vp.sellerID.Int64 != prod.userID:
		return fallback("purchase seller")
	case prod.productCurrency() != "usd" && !plainDecimal.MatchString(vp.rate.String):
		return fallback("purchase currency")
	}
	if !vp.zipTaxRateID.Valid || !taxable && vp.gumroadTaxCents.Int64 <= 0 && vp.taxCents.Int64 <= 0 {
		return nil
	}
	missing, err := h.exists(p.Ctx, "SELECT 1 FROM zip_tax_rates WHERE zip_tax_rates.id = ? AND zip_tax_rates.combined_rate IS NULL",
		vp.zipTaxRateID.Int64)
	if err != nil || missing {
		return firstErr(err, fallback("purchase tax rate"))
	}
	return nil
}

// hasStampablePDFs is Link#has_stampable_pdfs?.
func hasStampablePDFs(files []productFile) bool {
	for _, f := range files {
		if f.filetype.String == "pdf" && f.flags&productFilePDFStampEnabled != 0 {
			return true
		}
	}
	return false
}

// purchaseSubscription is the purchase's subscription, nil without one.
type purchaseSubscription struct {
	id                             int64
	chargeOccurrenceCount          sql.NullInt64
	failedAt, endedAt, cancelledAt db.NullTime
}

func (s *purchaseSubscription) alive(now time.Time) bool {
	return s != nil && !s.failedAt.Valid && !s.endedAt.Valid && (!s.cancelledAt.Valid || s.cancelledAt.Time.After(now))
}

func (h *handler) purchaseSubscription(p *page, vp *visitorPurchase) (*purchaseSubscription, error) {
	if !vp.subscriptionID.Valid {
		return nil, nil
	}
	s := &purchaseSubscription{}
	err := h.c.DB.QueryRowContext(p.Ctx, "SELECT subscriptions.id, subscriptions.charge_occurrence_count, subscriptions.failed_at,"+
		" subscriptions.ended_at, subscriptions.cancelled_at FROM subscriptions WHERE subscriptions.id = ? LIMIT 1",
		vp.subscriptionID.Int64).Scan(&s.id, &s.chargeOccurrenceCount, &s.failedAt, &s.endedAt, &s.cancelledAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return s, err
}

// formattedTotal is formatted_total_transaction_amount: the total in the purchase's currency,
// with price_for_recurrence's recurrence after it.
func (h *handler) formattedTotal(p *page, vp *visitorPurchase, sub *purchaseSubscription) (string, error) {
	currency := vp.currency.String
	amount := vp.totalTransactionCents.Int64
	if currency != "usd" {
		var ok bool
		// BigDecimal(nil) raises; usd_cents_to_currency returns USD's nil as is, which formats as 0.
		if amount, ok = usdCentsToCurrency(currency, amount, vp.rate.String); !ok || !vp.totalTransactionCents.Valid {
			return "", fallback("purchase currency")
		}
	}
	price, ok := formatJustPriceInCents(amount, currency)
	if !ok {
		return "", fallback("purchase currency")
	}
	recurrence, found, err := h.priceForRecurrence(p, vp, sub)
	if err != nil || !found {
		return price, err
	}
	single := sub != nil && sub.chargeOccurrenceCount.Valid && sub.chargeOccurrenceCount.Int64 == 1
	// formatted_price_with_recurrence.
	if recurrence.Valid && single {
		return price + " once", nil
	}
	if recurrence.Valid {
		price += " " + recurrenceLongIndicators[recurrence.String]
	}
	if single {
		price += " x 1"
	}
	return price, nil
}

// priceForRecurrence is price || subscription&.price's recurrence, found false for neither.
// Subscription#price is last_payment_option's, else the last alive option's.
func (h *handler) priceForRecurrence(p *page, vp *visitorPurchase, sub *purchaseSubscription) (recurrence sql.NullString, found bool, err error) {
	ctx := p.Ctx
	if vp.priceID.Valid {
		err = h.c.DB.QueryRowContext(ctx, "SELECT prices.recurrence FROM prices WHERE prices.id = ? LIMIT 1", vp.priceID.Int64).Scan(&recurrence)
		if err == nil || !errors.Is(err, sql.ErrNoRows) {
			return recurrence, err == nil, err
		}
	}
	if sub == nil {
		return recurrence, false, nil
	}
	var optionID, priceID sql.NullInt64
	err = h.c.DB.QueryRowContext(ctx, "SELECT payment_options.id, prices.id, prices.recurrence FROM subscriptions"+
		" LEFT JOIN payment_options ON payment_options.id = subscriptions.last_payment_option_id"+
		" LEFT JOIN prices ON prices.id = payment_options.price_id WHERE subscriptions.id = ? LIMIT 1", sub.id).Scan(&optionID, &priceID, &recurrence)
	if err != nil {
		return recurrence, false, err
	}
	if !optionID.Valid {
		err = h.c.DB.QueryRowContext(ctx, "SELECT payment_options.id, prices.id, prices.recurrence FROM payment_options"+
			" LEFT JOIN prices ON prices.id = payment_options.price_id WHERE payment_options.subscription_id = ?"+
			" AND payment_options.deleted_at IS NULL ORDER BY payment_options.id DESC LIMIT 1", sub.id).Scan(&optionID, &priceID, &recurrence)
		if errors.Is(err, sql.ErrNoRows) {
			// nil.price raises.
			return recurrence, false, fallback("subscription payment option")
		}
		if err != nil {
			return recurrence, false, err
		}
	}
	return recurrence, priceID.Valid, nil
}

// purchaseReview is original_product_review's review_form_props: the review on the
// subscription's original purchase, or on this one.
func (h *handler) purchaseReview(p *page, vp *visitorPurchase, sub *purchaseSubscription) (any, error) {
	ctx := p.Ctx
	purchaseID := sql.NullInt64{Int64: vp.id, Valid: true}
	if vp.subscriptionID.Valid {
		if sub == nil {
			// subscription.true_original_purchase raises on a missing subscription.
			return nil, fallback("purchase subscription")
		}
		err := h.c.DB.QueryRowContext(ctx, "SELECT purchases.id FROM purchases WHERE purchases.subscription_id = ?"+
			" AND (purchases.flags & ?) != 0 ORDER BY purchases.id ASC LIMIT 1", sub.id, purchaseIsOriginalSubscription).Scan(&purchaseID.Int64)
		if errors.Is(err, sql.ErrNoRows) {
			return nil, nil
		}
		if err != nil {
			return nil, err
		}
	}
	var id int64
	var anonymous sql.NullBool
	var rating sql.NullInt64
	var message sql.NullString
	err := h.c.DB.QueryRowContext(ctx, "SELECT product_reviews.id, product_reviews.anonymous, product_reviews.rating, product_reviews.message"+
		" FROM product_reviews WHERE product_reviews.purchase_id = ? LIMIT 1", purchaseID.Int64).Scan(&id, &anonymous, &rating, &message)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	video, err := h.exists(ctx, "SELECT 1 FROM product_review_videos WHERE product_review_videos.product_review_id = ?"+
		" AND product_review_videos.deleted_at IS NULL AND product_review_videos.approval_status IN ('pending_review', 'approved') LIMIT 1", id)
	if err != nil || video {
		return nil, firstErr(err, fallback("purchase review video"))
	}
	return rails.NewRHash().
		Sym("anonymous", anonymous.Bool).
		Sym("rating", nullInt(rating)).
		Sym("message", nullString(message)).
		Sym("video", nil), nil
}

// raterAccountName is Purchase#rater_account_name.
func (h *handler) raterAccountName(p *page, vp *visitorPurchase) (any, error) {
	if !vp.purchaserID.Valid || vp.flags&purchaseIsGiftReceiver != 0 && rails.Present(vp.streetAddress.String) {
		return nil, nil
	}
	var name, username sql.NullString
	err := h.c.DB.QueryRowContext(p.Ctx, "SELECT users.name, users.username FROM users WHERE users.id = ? LIMIT 1",
		vp.purchaserID.Int64).Scan(&name, &username)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return nil, nil
	case err != nil:
		return nil, err
	case rails.Present(name.String):
		return name.String, nil
	case rails.Present(username.String):
		return username.String, nil
	}
	return nil, nil
}

// purchaseMembership is purchase_info's membership for a tiered membership.
func (h *handler) purchaseMembership(p *page, prod *product, vp *visitorPurchase, sub *purchaseSubscription) (any, error) {
	var name, description any
	var tierName, tierDescription sql.NullString
	err := h.c.DB.QueryRowContext(p.Ctx, "SELECT base_variants.name, base_variants.description FROM base_variants"+
		" INNER JOIN base_variants_purchases ON base_variants.id = base_variants_purchases.base_variant_id"+
		" WHERE base_variants_purchases.purchase_id = ? ORDER BY base_variants.id ASC LIMIT 1", vp.id).Scan(&tierName, &tierDescription)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}
	if err == nil {
		name, description = nullString(tierName), nullString(tierDescription)
		if tierName.Valid && tierName.String == "Untitled" {
			name = prod.name
		}
	}
	var manageURL any
	if sub != nil {
		manageURL = h.c.Env.Protocol + "://" + h.c.Env.Domain + "/subscriptions/" + h.c.IDs.Encrypt(sub.id) + "/manage"
	}
	return rails.NewRHash().Sym("tier_name", name).Sym("tier_description", description).Sym("manage_url", manageURL), nil
}
