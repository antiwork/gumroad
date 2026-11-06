package licenses

import (
	"database/sql"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/rails"
)

type idEncoder interface {
	Encrypt(id int64) string
	EncryptNumeric(id int64) (int64, bool)
}

// buildPurchaseJSON is purchase.payload_for_ping_notification.Merge(purchase_as_json(purchase)).
// Errors stand for the exceptions Ruby would raise, which render a 500.
func buildPurchaseJSON(g *purchaseGraph, cfg *config, ids idEncoder) (*rails.RHash, error) {
	p, link := g.purchase, g.product
	if g.seller == nil || link == nil {
		return nil, fmt.Errorf("purchase %d: %w (seller or link)", p.id, errMissingRecord)
	}
	productURL, err := cfg.longURL(link, g.productUser)
	if err != nil {
		return nil, err
	}

	payload := rails.NewRHash().
		Sym("seller_id", ids.Encrypt(g.seller.id)).
		Sym("product_id", ids.Encrypt(link.id)).
		Sym("product_name", link.name).
		Sym("permalink", generalPermalink(link)).
		Sym("product_permalink", productURL).
		Sym("short_product_id", nullString(link.uniquePermalink)).
		Sym("email", nullString(p.email)).
		Sym("price", nullInt(p.priceCents)).
		Sym("gumroad_fee", nullInt(p.feeCents)).
		Sym("currency", nullString(link.priceCurrencyType)).
		Sym("quantity", p.quantity).
		Sym("discover_fee_charged", p.is(purchaseWasDiscoverFeeCharged)).
		Sym("can_contact", p.canContact.Valid && p.canContact.Bool).
		Sym("referrer", nullString(p.referrer)).
		Sym("card", rails.NewRHash().
			Sym("visual", nullString(p.cardVisual)).
			Sym("type", nullString(p.cardType)).
			Sym("bin", nil).
			Sym("expiry_month", nil).
			Sym("expiry_year", nil))

	orderNumber, ok := ids.EncryptNumeric(p.id)
	if !ok {
		return nil, fmt.Errorf("purchase %d is past encrypt_numeric's range", p.id)
	}
	payload.Sym("order_number", orderNumber)
	payload.Sym("sale_id", ids.Encrypt(p.id))
	payload.Sym("sale_timestamp", p.createdAt.OrNil())
	if presentString(p.fullName) {
		payload.Sym("full_name", p.fullName.String)
	}
	if g.purchaser != nil {
		payload.Sym("purchaser_id", nullString(g.purchaser.externalID))
	}
	if g.subscription != nil {
		payload.Sym("subscription_id", ids.Encrypt(g.subscription.id))
	}
	if g.hasAffiliateCredit {
		payload.Sym("affiliate_credit_amount_cents", ownAffiliateCreditCents(g))
	}
	if len(g.variants) > 0 {
		// variant_names_hash's value; purchase_as_json's variants replaces it below.
		payload.Sym("variants", nil)
	}
	if g.offerCode != nil {
		payload.Sym("offer_code", nullString(g.offerCode.code))
	}
	if g.purchaser != nil && g.purchaser.id == g.seller.id {
		payload.Sym("test", true)
	}
	if g.isRecurringSubscriptionCharge() {
		payload.Sym("is_recurring_charge", true)
	}
	if p.is(purchaseIsPreorderAuthorization) {
		payload.Sym("is_preorder_authorization", true)
	}
	if link.requireShipping.Valid && link.requireShipping.Bool {
		// Purchase#shipping_information: each attribute, or "" when it is nil.
		shipping := rails.NewRHash().
			Sym("full_name", p.fullName.String).
			Sym("street_address", p.streetAddress.String).
			Sym("country", p.country.String).
			Sym("state", p.state.String).
			Sym("zip_code", p.zipCode.String).
			Sym("city", p.city.String)
		payload.Merge(shipping)
		payload.Sym("shipping_information", shipping)
	}
	for _, field := range g.customFields {
		payload.Str(field.name, field.rubyValue())
	}
	if len(g.customFields) > 0 || len(g.subscriptionCustomFields) > 0 {
		// custom_fields.pluck(:name, :value).to_h; purchase_as_json's array replaces it below.
		payload.Sym("custom_fields", nil)
	}
	if licenseKey := g.licenseKey(); licenseKey != "" {
		payload.Sym("license_key", licenseKey)
		payload.Sym("is_multiseat_license", p.is(purchaseIsMultiseatLicense))
	}
	if presentString(p.ipCountry) {
		payload.Sym("ip_country", p.ipCountry.String)
	}
	if link.is(linkIsPhysical) {
		payload.Sym("shipping_rate", nullInt(p.shippingCents))
	}
	if g.subscription != nil {
		if g.subscription.recurrenceErr != nil {
			return nil, g.subscription.recurrenceErr
		}
		payload.Sym("recurrence", nullString(g.subscription.recurrence))
	}
	if g.affiliate != nil {
		if g.affiliateUser == nil {
			return nil, fmt.Errorf("affiliate %d: %w (affiliate_user)", g.affiliate.id, errMissingRecord)
		}
		payload.Sym("affiliate", g.affiliateUser.formEmail())
	}
	payload.Sym("is_gift_receiver_purchase", p.is(purchaseIsGiftReceiverPurchase))
	if p.is(purchaseIsGiftReceiverPurchase) {
		if g.gift == nil || !g.gift.gifterFound {
			return nil, fmt.Errorf("purchase %d: %w (gift)", p.id, errMissingRecord)
		}
		payload.Sym("gift_price", nullInt(g.gift.priceCents))
		payload.Sym("gifter_email", nullString(g.gift.email))
	}
	if link.is(linkSkusEnabled) || link.is(linkIsPhysical) {
		payload.Sym("sku_id", skuCustomNameOrExternalID(g, ids))
		if sku := g.sku(); sku != nil && presentString(sku.customSku) {
			payload.Sym("original_sku_id", ids.Encrypt(sku.id))
		}
	}
	payload.Sym("refunded", p.stripeRefunded.Valid && p.stripeRefunded.Bool)
	payload.Sym("disputed", p.chargebackDate.Valid)
	payload.Sym("dispute_won", p.is(purchaseChargebackReversed))

	license, err := purchaseAsJSONForLicense(g, ids)
	if err != nil {
		return nil, err
	}
	return payload.Merge(license), nil
}

// purchaseAsJSONForLicense is as_json_for_license kept to WHITELIST_PURCHASE_ATTRIBUTES, in
// as_json's key order. as_json computes many more fields; only these reach the response.
func purchaseAsJSONForLicense(g *purchaseGraph, ids idEncoder) (*rails.RHash, error) {
	p, link := g.purchase, g.product
	refunded := p.stripeRefunded.Valid && p.stripeRefunded.Bool
	asJSON := rails.NewRHash().Sym("id", ids.Encrypt(p.id))
	if p.createdAt.Valid {
		asJSON.Sym("created_at", p.createdAt.Time)
	}
	if p.stripeRefunded.Valid {
		asJSON.Sym("refunded", refunded)
	}
	asJSON.Sym("variants", variantsList(g.variants))
	fields := make([]string, len(g.customFields))
	for i, field := range g.customFields {
		fields[i] = field.name + ": " + rails.ToS(field.rubyValue())
	}
	asJSON.Sym("custom_fields", fields)
	if g.offerCode != nil {
		displayed, err := displayedAmountOff(g.offerCode, link.priceCurrencyType)
		if err != nil {
			return nil, err
		}
		asJSON.Sym("offer_code", rails.NewRHash().
			Sym("code", nullString(g.offerCode.code)).
			Sym("displayed_amount_off", displayed).
			Sym("name", nullString(g.offerCode.code)))
	}
	if link.is(linkIsRecurringBilling) {
		if g.subscription == nil {
			return nil, fmt.Errorf("purchase %d of a recurring product: %w (subscription)", p.id, errMissingRecord)
		}
		asJSON.Sym("subscription_ended_at", g.subscription.endedAt.OrNil()).
			Sym("subscription_cancelled_at", g.subscription.cancelledAt.OrNil()).
			Sym("subscription_failed_at", g.subscription.failedAt.OrNil())
	} else {
		asJSON.Sym("chargebacked", p.chargebackDate.Valid && !p.is(purchaseChargebackReversed))
		asJSON.Sym("refunded", refunded)
	}
	return asJSON, nil
}

// displayedAmountOff is original_offer_code(include_deleted: true)&.displayed_amount_off(
// link.price_currency_type, with_symbol: true). Money.new treats a nil currency as USD.
func displayedAmountOff(o *offerCode, currency sql.NullString) (string, error) {
	code := "usd"
	if currency.Valid {
		code = currency.String
	}
	switch {
	case o.discountAmount.Valid && o.discountIsPercent.Bool:
		return strconv.FormatInt(o.discountAmount.Int64, 10) + "%", nil
	case o.discountAmount.Valid:
		return formatMoney(o.discountAmount.Int64, code)
	case o.amountCents.Valid:
		return formatMoney(o.amountCents.Int64, code)
	}
	return rails.ToS(nullInt(o.amountPercentage)) + "%", nil
}

// variantsList is Purchase#variants_list through ProductsHelper#variants_displayable.
func variantsList(variants []*baseVariant) string {
	var shown []*baseVariant
	for _, v := range variants {
		if v.flags&baseVariantIsDefaultSku == 0 {
			shown = append(shown, v)
		}
	}
	if len(shown) == 0 || (len(shown) == 1 && shown[0].name.Valid && shown[0].name.String == "Untitled") {
		return ""
	}
	names := make([]string, len(shown))
	for i, v := range shown {
		names[i] = v.name.String
	}
	return "(" + strings.Join(names, ", ") + ")"
}

// sku is Purchase#sku: the first variant attribute when it is a Sku.
func (g *purchaseGraph) sku() *baseVariant {
	if len(g.variants) > 0 && g.variants[0].isSku() {
		return g.variants[0]
	}
	return nil
}

// skuCustomNameOrExternalID is Purchase#sku_custom_name_or_external_id.
func skuCustomNameOrExternalID(g *purchaseGraph, ids idEncoder) string {
	if sku := g.sku(); sku != nil {
		if presentString(sku.customSku) {
			return sku.customSku.String
		}
		return ids.Encrypt(sku.id)
	}
	if g.product.is(linkIsPhysical) && len(g.variants) > 0 {
		return ids.Encrypt(g.variants[0].id)
	}
	return "pid_" + ids.Encrypt(g.product.id)
}

// licenseKey is Purchase#license_key when present?, else "".
func (g *purchaseGraph) licenseKey() string {
	if g.licenseKeyPermitted && presentString(g.licenseSerial) {
		return g.licenseSerial.String
	}
	return ""
}

// ownAffiliateCreditCents is Purchase#own_affiliate_credit_cents.
func ownAffiliateCreditCents(g *purchaseGraph) int64 {
	cents := g.purchase.affiliateCreditCents.Int64
	if !g.directAffiliate {
		return cents
	}
	direct, _ := jsonInt(g.jsonData["direct_affiliate_credit_cents"])
	return cents - direct
}

func generalPermalink(link *product) any {
	if presentString(link.customPermalink) {
		return link.customPermalink.String
	}
	return nullString(link.uniquePermalink)
}

// longURL is Link#long_url: short_link_url on the seller's subdomain.
func (cfg *config) longURL(link *product, owner *user) (string, error) {
	if owner == nil {
		return "", fmt.Errorf("link %d: %w (user)", link.id, errMissingRecord)
	}
	permalink, ok := generalPermalink(link).(string)
	if !ok {
		return "", fmt.Errorf("link %d has no permalink to build a URL from", link.id)
	}
	username := owner.username
	if !presentString(username) {
		username = owner.externalID
	}
	return cfg.env.ProductLongURL(username.String, permalink), nil
}

// importedCustomerJSON is ImportedCustomer#as_json(without_license_key: true).
func importedCustomerJSON(c *importedCustomer, ids idEncoder, now time.Time) (*rails.RHash, error) {
	if !c.purchaseDate.Valid {
		return nil, fmt.Errorf("imported customer %d has no purchase_date for time_ago_in_words", c.id)
	}
	linkName := nullString(c.linkName)
	return rails.NewRHash().
		Str("email", nullString(c.email)).
		Str("created_at", c.createdAt).
		Sym("timestamp", timeAgoInWords(c.purchaseDate.Time, now)+" ago").
		Sym("link_name", linkName).
		Sym("product_name", linkName).
		Sym("price", nil).
		Sym("is_imported_customer", true).
		Sym("purchase_email", nullString(c.email)).
		Sym("id", ids.Encrypt(c.id)).
		Sym("can_update", nil), nil
}
