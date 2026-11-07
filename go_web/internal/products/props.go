package products

import (
	"slices"
	"strings"

	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/web"
)

// productProps adds ProductPresenter::ProductProps#props, in its key order, for the product shapes
// unportedShape lets through.
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
		pwyw = rails.NewRHash().Sym("suggested_price_cents", suggested).Sym("default_price_cents", pwywDefault(prod, v))
	}
	// Link#rental.
	var rental any
	if r := v.prices.rental; r != nil {
		rental = rails.NewRHash().Sym("price_cents", *r).Sym("rent_only", prod.rentOnly())
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
		Sym("is_stream_only", slices.ContainsFunc(v.files, productFile.streamOnly)).
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
		Sym("rental_price_cents", intOrNil(v.prices.rental)).
		Sym("pwyw", pwyw).
		Sym("eligible_for_installment_plans", installmentEligible(prod)).
		Sym("allow_installment_plan", v.installmentPlan != nil).
		Sym("installment_plan", v.installmentPlan).
		Sym("is_legacy_subscription", prod.is(productIsRecurringBilling) && !prod.is(productIsTieredMembership)).
		Sym("is_tiered_membership", prod.is(productIsTieredMembership)).
		Sym("is_recurring_billing", prod.is(productIsRecurringBilling)).
		Sym("is_physical", prod.is(productIsPhysical)).
		Sym("custom_view_content_button_text", presence(j.get("custom_view_content_button_text"))).
		Sym("is_multiseat_license", prod.is(productIsMultiseatLicense) && prod.nativeType != "call").
		Sym("is_licensed", prod.is(productIsLicensed)).
		Sym("hide_sold_out_variants", prod.is(productHideSoldOutVariants)).
		Sym("native_type", prod.nativeType).
		Sym("preorder", v.preorder).
		Sym("duration_in_months", nullInt(prod.durationInMonths)).
		Sym("rental", rental).
		Sym("is_quantity_enabled", prod.is(productQuantityEnabled)).
		Sym("free_trial", freeTrialProps(prod)).
		Sym("recurrences", v.recurrences.props()).
		Sym("options", h.optionsProps(prod, v.variants, v.tierRecurrences)).
		Sym("analytics", analyticsData(seller, v.sellerJSON)).
		Sym("has_third_party_analytics", v.thirdPartyAnalytics).
		Sym("ppp_details", v.ppp.props()).
		Sym("can_edit", p.canEdit()).
		Sym("waitlist", h.waitlistProps(prod, v)).
		Sym("refund_policy", v.refundPolicy).
		Sym("bundle_products", v.bundle.props).
		Sym("public_files", v.publicFiles).
		Sym("file_summaries", v.fileSummaries)

	discountCode := v.discount.resultProps()
	props.Sym("product", product).
		Sym("discount_code", discountCode).
		Sym("sale_label", v.discount.label).
		Sym("selection_discounts", selectionDiscounts(p, prod, v, discountCode)).
		Sym("purchase", v.purchase).
		Sym("wishlists", v.wishlists)
}

// pwywDefault is pwyw_default_price_cents.
func pwywDefault(prod *product, v *view) any {
	if prod.is(productIsRecurringBilling) || v.priceCents == nil || *v.priceCents != 0 || prod.suggestedPriceCents.Int64 != 0 {
		return nil
	}
	if r := v.prices.rental; r != nil && *r != 0 {
		return nil
	}
	for _, o := range v.variants.options {
		if o.priceDifference.Int64 != 0 {
			return nil
		}
	}
	return int64(0)
}

// installmentEligible is ProductInstallmentPlan.eligible_for_product?.
func installmentEligible(prod *product) bool {
	if prod.is(productIsRecurringBilling) || prod.is(productIsTieredMembership) || prod.is(productIsInPreorderState) {
		return false
	}
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
// seller_custom_domain_url: the root URL of the subdomain or custom domain, and none on a
// product's domain, where profile_url takes the subdomain without its slash.
func (h *handler) authorByline(p *page, v *view) any {
	root := h.sellerCustomDomainURL(p)
	if p.productDomain {
		root = h.userProfileURL(p.seller)
	}
	// User#profile_url adds recommended_by as url_for_product_page does.
	return bylineProps(p.seller, v.avatarURL, root+productPageQuery("", p.recommendedBy))
}

// productPageURL is url_for_product_page for one of the seller's products: short_link_url on
// this host in the request's protocol, http on a custom domain, or long_url on a product's
// domain, where user_by_domain finds no seller.
func (h *handler) productPageURL(p *page, permalink, query string) string {
	if p.productDomain {
		return h.c.Env.ProductLongURL(sellerUsername(p.seller), permalink) + query
	}
	return web.Protocol(p.Req.HTTP) + p.Req.Host + "/l/" + web.EscapeSegment(permalink) + query
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

// userProfileURL is User#profile_url without a custom domain: subdomain_with_protocol, no
// trailing slash.
func (h *handler) userProfileURL(u *user) string {
	return h.c.Env.Protocol + "://" + h.userSubdomain(u)
}

// canonicalURL is product.long_url(host: custom_domain_host_for_meta(product)): on the seller's
// own custom domain, the request's host.
func (h *handler) canonicalURL(p *page, prod *product) string {
	if p.customDomain {
		return h.shortLinkURL(p, prod.generalPermalink())
	}
	return h.c.Env.ProductLongURL(sellerUsername(p.seller), prod.generalPermalink())
}

// shortLinkURL is short_link_url on the request's host, in default_url_options' protocol: https
// even on a custom domain.
func (h *handler) shortLinkURL(p *page, permalink string) string {
	return h.c.Env.Protocol + "://" + p.Req.Host + "/l/" + web.EscapeSegment(permalink)
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

// sectionsProps is ProfileSectionsPresenter#props for the product's own sections. render fills
// in the sections; the placeholder keeps the key where Rails has it.
func (h *handler) sectionsProps(p *page, v *view) *rails.RHash {
	seller := p.seller
	// seller.name || seller.username: an empty name is still a name.
	var name any = sellerUsername(seller)
	if seller.name.Valid {
		name = seller.name.String
	}
	profile := rails.NewRHash().
		Sym("external_id", nullString(seller.externalID)).
		Sym("avatar_url", v.avatarURL).
		Sym("name", name).
		Sym("twitter_handle", nullString(seller.twitterHandle)).
		Sym("youtube_channel_id", v.youtubeChannelID).
		Sym("subdomain", h.userSubdomain(seller)).
		Sym("is_verified", seller.verified.Bool).
		Sym("can_edit", p.ownView() && p.hasRole(teamAdmin, teamMarketing)).
		Sym("follow_recaptcha_site_key", v.recaptchaSiteKey).
		Sym("hide_follow_form", seller.is(userHideFollowForm))
	if v.reputationEnabled {
		profile.Sym("reputation", v.profileReputation)
	}
	props := rails.NewRHash().
		Sym("currency_code", viewerCurrency(p)).
		Sym("show_ratings_filter", v.showRatingsFilter).
		Sym("creator_profile", profile).
		Sym("sections", []any{})
	if v.editor != nil {
		props.Merge(v.editor)
	}
	return props
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

// buyerLocalPriceProps is buyer_local_price_props.
func buyerLocalPriceProps(props *rails.RHash, productCurrency string, c *currencyDisplay) {
	if c == nil {
		return
	}
	props.Sym("buyer_currency", c.buyer).
		Sym("buyer_local_currency_rate", minorUnitRate(c.rate, productCurrency, c.buyer)).
		Sym("buyer_local_currency_subunit_to_unit", unitScalingFactor(c.buyer)).
		Sym("buyer_local_price_cents", c.localCents)
	if c.originalLocalCents != nil {
		props.Sym("buyer_local_original_price_cents", *c.originalLocalCents)
	}
}
