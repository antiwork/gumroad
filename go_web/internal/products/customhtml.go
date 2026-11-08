package products

import (
	"context"
	"database/sql"
	_ "embed"
	"errors"
	"net/http"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/customstyles"
	"github.com/antiwork/gumroad/go_web/internal/db"
	"github.com/antiwork/gumroad/go_web/internal/description"
	"github.com/antiwork/gumroad/go_web/internal/html4"
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

// customHTMLLiveReload is custom_html_live_reload_script's heredoc, filled the same way.
//
//go:embed custom_html_live_reload.html
var customHTMLLiveReload string

// customHTMLPollInterval is RendersCustomHtmlPages::POLL_INTERVAL_MS.
const customHTMLPollInterval = "2000"

// customDomainCertificateLifetime is CustomDomain::CERTIFICATE_LIFETIME.
const customDomainCertificateLifetime = 90 * 24 * time.Hour

// waitlistFormFound is Pages::WaitlistForm.found_in?: the signup message, or a
// form[data-gumroad-waitlist] anywhere in Loofah's HTML4 fragment parse.
func waitlistFormFound(html string) (bool, error) {
	if strings.Contains(html, "gumroad:waitlist") {
		return true, nil
	}
	frag, err := html4.ParseFragment(html)
	if errors.Is(err, html4.ErrUnported) {
		return false, fallback("custom html waitlist")
	}
	if err != nil {
		return false, err
	}
	var holds func(n *html4.Node) bool
	holds = func(n *html4.Node) bool {
		for c := n.FirstChild; c != nil; c = c.NextSibling {
			if c.Type == html4.ElementNode && c.Name == "form" {
				if _, ok := c.Attr("data-gumroad-waitlist"); ok {
					return true
				}
			}
			if holds(c) {
				return true
			}
		}
		return false
	}
	return holds(frag), nil
}

// renderCustomHTML is render_custom_html_if_present, whose wanted and review link serve has
// checked and whose native and code params declinedParams left to Rails. It answers an
// autocomplete partial reload with the same document, since it renders before show.
func (h *handler) renderCustomHTML(w http.ResponseWriter, p *page, prod *product) error {
	pc, ctx, seller := h.c.Page, p.Ctx, p.seller
	// can_preview_product_custom_html? adds the live reload for the seller and a collaborator;
	// staff went to Rails already.
	preview := false
	if logged := p.Auth.LoggedInUser(); logged != nil {
		if preview = logged.ID == prod.userID; !preview {
			var err error
			if preview, err = h.collaboratorFor(ctx, logged.ID, prod.id); err != nil {
				return err
			}
		}
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
	canonical := h.canonicalURL(p, prod)
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
		var demo string
		if rails.Present(shareImage) {
			if demo, err = h.demoPlayerURL(p, prod, v); err != nil {
				return err
			}
		}
		escaped := web.HTMLEscape(shareImage)
		card := `<meta property="twitter:card" content="summary_large_image">` + "\n    " +
			`<meta property="twitter:image" content="` + escaped + `">`
		if demo != "" {
			card = `<meta property="twitter:card" content="player">` + "\n    " +
				`<meta property="twitter:image" content="` + escaped + `">` + "\n    " +
				`<meta property="twitter:player" content="` + web.HTMLEscape(demo) + `">` + "\n    " +
				`<meta property="twitter:player:width" content="` + strconv.Itoa(demoPlayerWidth) + `">` + "\n    " +
				`<meta property="twitter:player:height" content="` + strconv.Itoa(demoPlayerHeight) + `">`
		}
		shareImageTags = `<meta property="og:image" content="` + escaped + "\">\n    " + card
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
	liveReload := ""
	if preview {
		liveReload = strings.NewReplacer(
			"«nonce»", web.HTMLEscape(nonce),
			"«version_src»", rails.EncodeJSON("/l/"+prod.uniquePermalink.String+"/landing/version"),
			"«poll_interval_ms»", customHTMLPollInterval,
		).Replace(customHTMLLiveReload)
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
		"«checkout_url»", rails.EncodeJSON("/l/"+prod.uniquePermalink.String+"?"+wrapperCheckoutQuery(p)),
		"«store_hostnames»", rails.EncodeJSON(hostnames),
		"«nav_hosts»", rails.EncodeJSON(h.c.Env.ValidRequestHosts),
		"«waitlist_script»", waitlist,
		"«live_reload_script»", liveReload,
	).Replace(customHTMLWrapper)

	if !p.DryRun {
		// Before the UTM visit, which a fallback to Rails would repeat.
		if err := h.pushVariants(ctx, p); err != nil {
			return err
		}
	}
	if err := h.trackUTMVisit(w, p, prod); err != nil {
		return err
	}
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
	if p.urlCode != "" {
		// set_x_robots_tag_header runs before this before_action.
		hdr.Set("X-Robots-Tag", "noindex")
	}
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
	// social_share_image reads the main cover's URL and no other's.
	if v.covers, err = h.loadCoverRows(ctx, prod.id); err != nil {
		return nil, err
	}
	if len(v.covers) > 0 {
		if err := h.coverURLs(ctx, p, v.covers[0]); err != nil {
			return nil, err
		}
		keepShareImageEffects(p, v.covers[0])
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

// keepShareImageEffects keeps, of the main cover's cache writes, social_share_image's: its url's
// entry, or a video's poster's.
func keepShareImageEffects(p *page, main *cover) {
	prefix := "attachment_" + itoa(main.attachmentID) + "_"
	read := main.urlCacheKey()
	if !main.previewImagePath() {
		read = prefix + "poster_url"
	}
	p.cacheWrites = slices.DeleteFunc(p.cacheWrites, func(pw pendingWrite) bool {
		return strings.HasPrefix(pw.key, prefix) && pw.key != read
	})
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
	// The has_one's statement, verbatim: it has no ORDER BY, so MySQL's plan picks the row.
	found := false
	err := scanNamed(ctx, h.c.DB, func(cols map[string]any) func() {
		cols["domain"], cols["state"], cols["ssl_certificate_issued_at"] = &domain, &state, &issued
		return func() { found = true }
	}, "SELECT `custom_domains`.* FROM `custom_domains` WHERE `custom_domains`.`user_id` = ? AND `custom_domains`.`deleted_at` IS NULL LIMIT 1",
		p.seller.id)
	switch {
	case err != nil:
		return nil, err
	case found && state.String == "verified" && issued.Valid && issued.Time.After(p.Req.Now.Add(-customDomainCertificateLifetime)) && domain.Valid:
		add(domain.String)
	}
	return hostnames, nil
}

// wrapperCheckoutQuery is the wrapper's Rack::Utils.build_query(checkout_params): wanted, then the
// URL's code when there is one, in that order.
func wrapperCheckoutQuery(p *page) string {
	if p.wrapperCode == "" {
		return "wanted=true"
	}
	return "wanted=true&code=" + rails.RackEscape(p.wrapperCode)
}
