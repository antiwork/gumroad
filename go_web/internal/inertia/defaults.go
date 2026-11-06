package inertia

// DefaultMeta is what PageMeta::Base and PageMeta::Analytics read from config.
type DefaultMeta struct {
	// default_page_title.
	Title string
	// Rails.env, FACEBOOK_APP_ID, STRIPE_PUBLIC_KEY and Stripe.api_version.
	Environment, FacebookAppID, StripePublicKey, StripeAPIVersion string
	// AssetHost is config.asset_host, which image_path prefixes.
	AssetHost string
	// AnalyticsByEnvironment is false outside production and staging, where
	// analytics_enabled? turns analytics off for any signed-in seller.
	AnalyticsByEnvironment bool
}

// Viewer is what the default tags read from the request.
type Viewer struct {
	// CSRFToken is form_authenticity_token.
	CSRFToken string
	// HasSeller and SellerDisablesAnalytics are current_seller and its
	// disable_third_party_analytics?.
	HasSeller, SellerDisablesAnalytics bool
	// LoggedInUserID is logged_in_user.external_id, "" when signed out.
	LoggedInUserID string
}

// Tags are ApplicationController's meta tags in the order its before_actions set them: the
// default title, the CSRF tags, the default tags and the analytics tags.
func (m DefaultMeta) Tags(v Viewer) *MetaTags {
	tags := NewMetaTags()
	meta := func(attrs ...string) { tags.Set(NewMetaTag("", "", "", Pairs(attrs...)...)) }
	link := func(headKey, typ string, attrs ...string) {
		tags.Set(NewMetaTag("link", headKey, typ, Pairs(attrs...)...))
	}

	meta("title", m.Title)
	meta("name", "csrf-param", "content", "authenticity_token")
	meta("name", "csrf-token", "content", v.CSRFToken)
	meta("charset", "utf-8")
	meta("property", "fb:app_id", "content", m.FacebookAppID)
	meta("property", "fb:page_id", "content", "http://www.facebook.com/gumroad")
	meta("property", "gr:environment", "content", m.Environment)
	meta("property", "og:image", "content", m.AssetHost+"/images/opengraph_image.png")
	meta("property", "og:image:alt", "content", "Gumroad")
	meta("property", "og:title", "content", "Gumroad")
	meta("property", "og:site_name", "content", "Gumroad")
	meta("name", "viewport", "content", "initial-scale = 1.0, width = device-width")
	meta("property", "stripe:pk", "value", m.StripePublicKey)
	meta("property", "stripe:api_version", "value", m.StripeAPIVersion)
	meta("property", "twitter:site", "content", "@gumroad")
	link("", "application/opensearchdescription+xml", "rel", "search", "href", "/opensearch.xml", "title", "Gumroad")
	link("shortcut-icon", "", "rel", "shortcut icon", "href", m.AssetHost+"/images/pink-icon.png")
	link("apple-touch-icon", "", "rel", "apple-touch-icon", "href", m.AssetHost+"/images/pink-icon.png")

	// analytics_enabled? with no @user: the current seller decides.
	enabled := "true"
	if v.HasSeller && (!m.AnalyticsByEnvironment || v.SellerDisablesAnalytics) {
		enabled = "false"
	}
	meta("property", "gr:google_analytics:enabled", "content", enabled)
	meta("property", "gr:fb_pixel:enabled", "content", enabled)
	meta("property", "gr:tiktok_pixel:enabled", "content", enabled)
	meta("property", "gr:logged_in_user:id", "content", v.LoggedInUserID)
	meta("property", "gr:page:type", "content", "")
	return tags
}

// Pairs is attributes from alternating keys and values.
func Pairs(kv ...string) []Attr {
	attrs := make([]Attr, 0, len(kv)/2)
	for i := 0; i+1 < len(kv); i += 2 {
		attrs = append(attrs, Attr{Key: kv[i], Value: kv[i+1]})
	}
	return attrs
}
