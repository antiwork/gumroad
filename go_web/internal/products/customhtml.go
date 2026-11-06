package products

import (
	"context"
	"database/sql"
	_ "embed"
	"errors"
	"net/http"
	"slices"
	"strings"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/customstyles"
	"github.com/antiwork/gumroad/go_web/internal/db"
	"github.com/antiwork/gumroad/go_web/internal/description"
	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/vite"
	"github.com/antiwork/gumroad/go_web/internal/web"
)

// customHTMLWrapper is product_custom_html_wrapper_document's heredoc as it renders, with each
// interpolation a «name» to fill. The seller's own HTML is never in it: the iframe loads that
// from /landing/embed, which Rails serves.
//
//go:embed custom_html_wrapper.html
var customHTMLWrapper string

// customHTMLWaitlist is custom_html_waitlist_wrapper_script's heredoc, filled the same way.
//
//go:embed custom_html_waitlist.html
var customHTMLWaitlist string

// customDomainCertificateLifetime is CustomDomain::CERTIFICATE_LIFETIME.
const customDomainCertificateLifetime = 90 * 24 * time.Hour

// renderCustomHTML is render_custom_html_if_present for a signed-out visitor, whose wanted,
// native, code and purchase_id params declinedParams already left to Rails.
func (h *handler) renderCustomHTML(w http.ResponseWriter, p *page, prod *product) error {
	pc, ctx, seller := h.c.Page, p.Ctx, p.seller
	if p.Auth.LoggedInUser() != nil {
		// can_preview_product_custom_html? and the live reload turn on the visitor.
		return fallback("signed-in custom html")
	}
	if pc.CustomHTMLAnalytics == nil {
		return fallback("custom html analytics entrypoint")
	}
	// The structured data reads the product as the page does; the page's other checks don't apply,
	// since Rails renders this before prepare_product_page.
	if reason := unportedProductShape(prod); reason != "" {
		return fallback(reason)
	}
	tracking := h.analyticsEnabled(seller)
	v, err := h.loadWrapperView(ctx, p, prod, tracking)
	if err != nil {
		return err
	}
	social, err := socialShareImage(v)
	if err != nil {
		return err
	}
	canonical := h.c.Env.ProductLongURL(sellerUsername(seller), prod.generalPermalink())
	data, err := h.structuredData(p, prod, v, canonical, social)
	if err != nil {
		return err
	}

	// product.thumbnail&.alive&.url || product.social_share_image.
	shareImage, hasShareImage := v.thumbnailURL.(string)
	if !hasShareImage && social != "" {
		shareImage, hasShareImage = social, true
	}
	var shareImageTags string
	if hasShareImage {
		// demo_player_card_meta, which is nil without a build.
		if err := h.noProductBuilds(ctx, prod); err != nil {
			return err
		}
		escaped := web.HTMLEscape(shareImage)
		shareImageTags = `<meta property="og:image" content="` + escaped + "\">\n    " +
			`<meta property="twitter:card" content="summary_large_image">` + "\n    " +
			`<meta property="twitter:image" content="` + escaped + `">`
	}

	text := "Available on Gumroad"
	if rails.Present(v.plaintextDescription) {
		text = v.plaintextDescription
	}
	hostnames, err := h.customHTMLStoreHostnames(ctx, p)
	if err != nil {
		return err
	}
	profile, err := h.sellerProfile(ctx, seller.id)
	if err != nil {
		return err
	}
	var background string
	if color, err := customstyles.WrapperBackground(profile); errors.Is(err, customstyles.ErrUnported) {
		return fallback("custom styles")
	} else if color != "" {
		background = "html{background:" + color + "}"
	}
	nonce := pc.NewNonce()
	waitlist := ""
	if prod.acceptsWaitlistSignups() {
		waitlist = strings.NewReplacer(
			"«nonce»", web.HTMLEscape(nonce),
			"«seller_id»", rails.EncodeJSON(nullString(seller.externalID)),
			"«product_id»", rails.EncodeJSON(h.c.IDs.Encrypt(prod.id)),
		).Replace(customHTMLWaitlist)
	}
	title := web.HTMLEscape(prod.name)
	body := strings.NewReplacer(
		"«title»", title,
		"«canonical»", web.HTMLEscape(canonical),
		"«meta_description»", web.HTMLEscape(description.Snippet(text)),
		"«share_image_tags»", shareImageTags,
		"«structured_data_tag»", `<script type="application/ld+json">`+rails.EncodeJSON(data)+"</script>",
		"«csrf_token»", web.HTMLEscape(p.MaskedCSRFToken()),
		"«analytics_head»", h.customHTMLAnalyticsHead(prod, seller, v, tracking),
		"«background_css»", background,
		"«description»", web.HTMLEscape(text),
		"«iframe_src»", web.HTMLEscape("/l/"+prod.uniquePermalink.String+"/landing/embed"),
		"«nonce»", web.HTMLEscape(nonce),
		"«checkout_url»", rails.EncodeJSON("/l/"+prod.uniquePermalink.String+"?wanted=true"),
		"«store_hostnames»", rails.EncodeJSON(hostnames),
		"«nav_hosts»", rails.EncodeJSON(h.c.Env.ValidRequestHosts),
		"«waitlist_script»", waitlist,
	).Replace(customHTMLWrapper)

	if !p.DryRun {
		h.flushCacheWrites(ctx, p)
	}
	// A before_action render halts the chain, so no XSRF-TOKEN cookie, and the flash stays unread.
	if err := h.ctl.Commit(w, p.Visit); err != nil {
		return err
	}
	hdr := w.Header()
	hdr.Set("Content-Security-Policy", pc.CSP.Header(nonce))
	hdr.Set("Link", vite.LinkHeader(*pc.CustomHTMLAnalytics))
	rails.RenderHTML(w, p.Req, body)
	return nil
}

// loadWrapperView loads, as loadView does, the parts of the view the wrapper reads.
func (h *handler) loadWrapperView(ctx context.Context, p *page, prod *product, tracking bool) (*view, error) {
	v := &view{}
	var ok bool
	if v.productJSON, ok = parseJSONData(prod.jsonData); !ok {
		return nil, fallback("product json_data")
	}
	if v.sellerJSON, ok = parseJSONData(p.seller.jsonData); !ok || !jsonScalar(v.sellerJSON.get("tiktok_pixel_id")) {
		return nil, fallback("seller json_data")
	}
	var err error
	if v.prices, err = h.loadPrices(ctx, prod); err != nil {
		return nil, err
	}
	if v.covers, err = h.loadCovers(ctx, p, prod.id); err != nil {
		return nil, err
	}
	if v.thumbnailURL, err = h.thumbnailURL(ctx, prod.id); err != nil {
		return nil, err
	}
	if prod.nativeType == "ebook" {
		if v.files, err = h.aliveProductFiles(ctx, prod.id); err != nil {
			return nil, err
		}
	}
	if prod.is(productDisplayReviews) {
		if v.reviewStat, err = h.loadReviewStat(ctx, prod.id); err != nil {
			return nil, err
		}
	}
	if v.variants, err = h.loadVariants(ctx, prod); err != nil {
		return nil, err
	}
	// availability_for_schema_org reads remaining_for_sale_count only under a max_purchase_count.
	if prod.maxPurchaseCount.Valid && prod.maxPurchaseCount.Int64 != 0 {
		if p.hasBundleProducts, err = h.exists(ctx, "SELECT 1 FROM bundle_products WHERE bundle_products.bundle_id = ?"+
			" AND bundle_products.deleted_at IS NULL LIMIT 1", prod.id); err != nil {
			return nil, err
		}
		b, err := h.loadBundle(ctx, p, prod)
		if err != nil {
			return nil, err
		}
		if v.quantityRemaining, err = h.remainingForSaleCount(ctx, prod, v.variants, b.quantityLeft); err != nil {
			return nil, err
		}
	}
	if err := h.loadDescription(ctx, prod, v); err != nil {
		return nil, err
	}
	if tracking {
		if v.thirdPartyAnalytics, err = h.hasThirdPartyAnalytics(ctx, prod); err != nil {
			return nil, err
		}
	}
	return v, nil
}

// customHTMLAnalyticsHead is custom_html_analytics_head.
func (h *handler) customHTMLAnalyticsHead(prod *product, seller *user, v *view, tracking bool) string {
	analytics := analyticsData(seller, v.sellerJSON)
	if !tracking {
		// Hash#merge keeps each key where it was.
		analytics.Sym("google_analytics_id", nil).Sym("facebook_pixel_id", nil).Sym("tiktok_pixel_id", nil)
	}
	pixel := tracking && slices.ContainsFunc([]string{"google_analytics_id", "facebook_pixel_id", "tiktok_pixel_id"},
		func(key string) bool { return rails.Present(analytics.Get(key)) })
	props := rails.NewRHash().
		Sym("seller_id", nullString(seller.externalID)).
		Sym("analytics", analytics).
		Sym("tracking_enabled", tracking).
		Sym("has_product_third_party_analytics", tracking && v.thirdPartyAnalytics).
		Sym("third_party_analytics_domain", h.c.Env.ThirdPartyAnalyticsDomain).
		Sym("permalink", nullString(prod.uniquePermalink)).
		Sym("name", prod.name)

	var b strings.Builder
	if pixel {
		b.WriteString("<meta property=\"gr:google_analytics:enabled\" content=\"true\">\n" +
			"<meta property=\"gr:fb_pixel:enabled\" content=\"true\">\n" +
			"<meta property=\"gr:tiktok_pixel:enabled\" content=\"true\">\n\n")
	}
	b.WriteString(`<meta name="gr:custom-html-analytics" content="`)
	web.WriteHTMLEscaped(&b, rails.EncodeJSON(props))
	b.WriteString("\">\n" + h.c.Page.CustomHTMLAnalytics.HTML)
	return b.String()
}

// customHTMLStoreHostnames is product_custom_html_store_hostnames: the request's host unless
// it's one of Gumroad's, then User#custom_html_store_hostnames.
func (h *handler) customHTMLStoreHostnames(ctx context.Context, p *page) ([]string, error) {
	hostnames := []string{}
	add := func(host string) {
		if !slices.Contains(hostnames, host) {
			hostnames = append(hostnames, host)
		}
	}
	if !h.c.Env.IsGumroadHost(p.Req.Host) {
		add(p.Req.Host)
	}
	add(h.userSubdomain(p.seller))
	// has_one :custom_domain, -> { alive }, then CustomDomain#active?.
	var domain, state sql.NullString
	var issued db.NullTime
	n, err := h.scanFirst(ctx, []any{&domain, &state, &issued}, "SELECT custom_domains.domain, custom_domains.state,"+
		" custom_domains.ssl_certificate_issued_at FROM custom_domains WHERE custom_domains.user_id = ?"+
		" AND custom_domains.deleted_at IS NULL LIMIT 2", p.seller.id)
	switch {
	case err != nil:
		return nil, err
	case n > 1:
		return nil, fallback("several custom domains")
	case n == 1 && state.String == "verified" && issued.Valid && issued.Time.After(p.Req.Now.Add(-customDomainCertificateLifetime)) && domain.Valid:
		add(domain.String)
	}
	return hostnames, nil
}
