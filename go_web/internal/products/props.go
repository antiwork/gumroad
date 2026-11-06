package products

import (
	"strings"

	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// productProps adds ProductPresenter::ProductProps#props for a signed-out visitor, in its key
// order, for the product shapes unportedShape lets through.
func (h *handler) productProps(props *rails.RHash, p *page, prod *product, v *view) {
	ids, seller := h.c.IDs, p.seller
	externalID := ids.Encrypt(prod.id)
	productCurrency := prod.productCurrency()
	j := v.productJSON

	covers := make([]any, len(v.covers))
	var mainCover any
	for i, c := range v.covers {
		covers[i] = c.json()
	}
	if len(v.covers) > 0 {
		mainCover = nullString(v.covers[0].guid)
	}
	var ratings any
	if prod.is(productDisplayReviews) {
		ratings = v.reviewStat.ratingStats()
	}
	var pwyw any
	if prod.customizablePrice.Bool {
		var suggested any
		if prod.suggestedPriceCents.Valid {
			suggested = prod.suggestedPriceCents.Int64
		}
		pwyw = rails.NewRHash().Sym("suggested_price_cents", suggested).Sym("default_price_cents", pwywDefault(prod, v.priceCents, v.variants))
	}

	product := rails.NewRHash().
		Sym("id", externalID).
		Sym("permalink", nullString(prod.uniquePermalink)).
		Sym("name", prod.name).
		Sym("seller", h.authorByline(p, v)).
		Sym("collaborating_user", v.collaborator).
		Sym("covers", covers).
		Sym("main_cover_id", mainCover).
		Sym("thumbnail_url", v.thumbnailURL).
		Sym("quantity_remaining", v.quantityRemaining).
		Sym("long_url", h.c.Env.ProductLongURL(sellerUsername(seller), prod.generalPermalink())).
		Sym("is_sales_limited", prod.maxPurchaseCount.Valid && prod.maxPurchaseCount.Int64 != 0).
		Sym("ratings", ratings)
	if v.reputationEnabled {
		product.Sym("seller_reputation", v.snapshotReputation)
	}
	product.
		Sym("custom_button_text_option", j.get("custom_button_text_option")).
		Sym("is_compliance_blocked", complianceBlocked(v.geo)).
		Sym("is_published", !prod.draft.Bool && prod.alive()).
		Sym("is_stream_only", false).
		Sym("streamable", hasFilegroup(v.files, "video")).
		Sym("sales_count", v.salesCount).
		Sym("summary", presence(j.get("custom_summary"))).
		Sym("attributes", v.attributes).
		Sym("description_html", v.descriptionHTML).
		Sym("currency_code", currencyCode(prod)).
		Sym("price_cents", intOrNil(v.priceCents)).
		Sym("buyer_currency_display", buyerCurrencyDisplay(externalID, productCurrency, v.currency))
	buyerLocalPriceProps(product, productCurrency, v.currency)
	product.
		Sym("rental_price_cents", nil).
		Sym("pwyw", pwyw).
		Sym("eligible_for_installment_plans", installmentEligible(prod)).
		Sym("allow_installment_plan", false).
		Sym("installment_plan", nil).
		Sym("is_legacy_subscription", false).
		Sym("is_tiered_membership", false).
		Sym("is_recurring_billing", false).
		Sym("is_physical", false).
		Sym("custom_view_content_button_text", presence(j.get("custom_view_content_button_text"))).
		Sym("is_multiseat_license", prod.is(productIsMultiseatLicense) && prod.nativeType != "call").
		Sym("is_licensed", prod.is(productIsLicensed)).
		Sym("hide_sold_out_variants", prod.is(productHideSoldOutVariants)).
		Sym("native_type", prod.nativeType).
		Sym("preorder", nil).
		Sym("duration_in_months", nullInt(prod.durationInMonths)).
		Sym("rental", nil).
		Sym("is_quantity_enabled", prod.is(productQuantityEnabled)).
		Sym("free_trial", nil).
		Sym("recurrences", nil).
		Sym("options", h.optionsProps(prod, v.variants)).
		Sym("analytics", analyticsData(seller, v.sellerJSON)).
		Sym("has_third_party_analytics", v.thirdPartyAnalytics).
		Sym("ppp_details", nil).
		Sym("can_edit", false).
		Sym("waitlist", nil).
		Sym("refund_policy", v.refundPolicy).
		Sym("bundle_products", []any{}).
		Sym("public_files", []any{}).
		Sym("file_summaries", v.fileSummaries)

	props.Sym("product", product).
		Sym("discount_code", nil).
		Sym("sale_label", nil).
		Sym("selection_discounts", rails.NewRHash().
			Sym("url_code", nil).
			Sym("quantity", int64(1)).
			Sym("recurrence", nil).
			Sym("option_id", nil).
			Sym("price_cents", nil).
			Sym("options", rails.NewRHash()).
			Sym("rent_options", nil)).
		Sym("purchase", nil).
		Sym("wishlists", []any{})
}

// pwywDefault is pwyw_default_price_cents without a rental.
func pwywDefault(prod *product, price *int64, vs *variants) any {
	if price == nil || *price != 0 || prod.suggestedPriceCents.Int64 != 0 {
		return nil
	}
	for _, o := range vs.options {
		if o.priceDifference.Int64 != 0 {
			return nil
		}
	}
	return int64(0)
}

// installmentEligible is ProductInstallmentPlan.eligible_for_product? for a product that is
// neither a membership nor a preorder.
func installmentEligible(prod *product) bool {
	switch prod.nativeType {
	case "call", "course", "digital", "ebook", "bundle":
		return true
	}
	return false
}

// currencyCode is (price_currency_type.presence || Currency::USD).downcase.
func currencyCode(prod *product) string {
	if rails.Present(prod.priceCurrencyType.String) {
		return rails.Downcase(prod.priceCurrencyType.String)
	}
	return "usd"
}

func hasFilegroup(files []productFile, group string) bool {
	for _, f := range files {
		if f.filegroup.Valid && f.filegroup.String == group {
			return true
		}
	}
	return false
}

func presence(v any) any {
	if rails.Present(v) {
		return v
	}
	return nil
}

func intOrNil(n *int64) any {
	if n == nil {
		return nil
	}
	return *n
}

// sellerUsername is User#username: the column, else the external id.
func sellerUsername(u *user) string {
	if rails.Present(u.username.String) {
		return u.username.String
	}
	return u.externalID.String
}

// analyticsData is User#analytics_data.
func analyticsData(u *user, j jsonData) *rails.RHash {
	return rails.NewRHash().
		Sym("google_analytics_id", nullString(u.googleAnalytics)).
		Sym("facebook_pixel_id", nullString(u.facebookPixel)).
		Sym("tiktok_pixel_id", presence(j.get("tiktok_pixel_id"))).
		Sym("free_sales", !u.is(userSkipFreeSaleAnalytics))
}

// authorByline is UserPresenter#author_byline_props with the request's
// seller_custom_domain_url: on the seller's subdomain that is its root URL.
func (h *handler) authorByline(p *page, v *view) any {
	return bylineProps(p.seller, v.avatarURL, h.sellerCustomDomainURL(p))
}

// bylineProps is UserPresenter#author_byline_props for u, nil without a username.
func bylineProps(u *user, avatarURL, profileURL string) any {
	if rails.Blank(sellerUsername(u)) {
		return nil
	}
	return rails.NewRHash().
		Sym("id", nullString(u.externalID)).
		Sym("name", nameOrUsername(u)).
		Sym("avatar_url", avatarURL).
		Sym("profile_url", profileURL).
		Sym("is_verified", u.verified.Bool)
}

// userSubdomain is User#subdomain: the username with dashes for underscores, under ROOT_DOMAIN.
func (h *handler) userSubdomain(u *user) string {
	return strings.ReplaceAll(sellerUsername(u), "_", "-") + "." + h.c.Env.RootDomain
}

// sellerCustomDomainURL is root_url(protocol: PROTOCOL, host: request.host_with_port).
func (h *handler) sellerCustomDomainURL(p *page) string {
	return h.c.Env.Protocol + "://" + p.Req.Host + "/"
}

// nameOrUsername is User#name_or_username.
func nameOrUsername(u *user) string {
	if rails.Present(u.name.String) {
		return u.name.String
	}
	return sellerUsername(u)
}

// sectionsProps is ProfileSectionsPresenter#props for the product's own sections, which
// unportedShape has checked are none.
func (h *handler) sectionsProps(p *page, v *view) *rails.RHash {
	seller := p.seller
	// seller.name || seller.username: an empty name is still a name.
	var name any = sellerUsername(seller)
	if seller.name.Valid {
		name = seller.name.String
	}
	var recaptcha any
	if v.recaptchaRequired {
		recaptcha = h.c.Page.RecaptchaSiteKey
	}
	profile := rails.NewRHash().
		Sym("external_id", nullString(seller.externalID)).
		Sym("avatar_url", v.avatarURL).
		Sym("name", name).
		Sym("twitter_handle", nullString(seller.twitterHandle)).
		Sym("youtube_channel_id", v.youtubeChannelID).
		Sym("subdomain", h.userSubdomain(seller)).
		Sym("is_verified", seller.verified.Bool).
		Sym("can_edit", false).
		Sym("follow_recaptcha_site_key", recaptcha).
		Sym("hide_follow_form", seller.is(userHideFollowForm))
	if v.reputationEnabled {
		profile.Sym("reputation", v.profileReputation)
	}
	return rails.NewRHash().
		Sym("currency_code", "usd").
		Sym("show_ratings_filter", v.showRatingsFilter).
		Sym("creator_profile", profile).
		Sym("sections", []any{})
}

// buyerCurrencyDisplay is buyer_currency_display_props' hash.
func buyerCurrencyDisplay(productID, productCurrency string, c *currencyDisplay) *rails.RHash {
	d := rails.NewRHash().Sym("product_id", productID)
	if c == nil {
		return d.Sym("buyer_currency_shown", productCurrency).
			Sym("product_currency", productCurrency).
			Sym("buyer_local_price_cents", nil).
			Sym("rate", nil).
			Sym("display_mode", "default")
	}
	return d.Sym("buyer_currency_shown", c.buyer).
		Sym("product_currency", productCurrency).
		Sym("buyer_local_price_cents", c.localCents).
		Sym("rate", c.rate).
		Sym("display_mode", "buyer_local")
}

// buyerLocalPriceProps is buyer_local_price_props without an original price: a discount is Rails'.
func buyerLocalPriceProps(props *rails.RHash, productCurrency string, c *currencyDisplay) {
	if c == nil {
		return
	}
	props.Sym("buyer_currency", c.buyer).
		Sym("buyer_local_currency_rate", minorUnitRate(c.rate, productCurrency, c.buyer)).
		Sym("buyer_local_currency_subunit_to_unit", unitScalingFactor(c.buyer)).
		Sym("buyer_local_price_cents", c.localCents)
}
