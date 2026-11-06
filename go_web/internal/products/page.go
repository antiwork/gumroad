package products

import (
	"context"
	"database/sql"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/redis/go-redis/v9"

	"github.com/antiwork/gumroad/go_web/internal/elastic"
	"github.com/antiwork/gumroad/go_web/internal/flipper"
	"github.com/antiwork/gumroad/go_web/internal/geoip"
	"github.com/antiwork/gumroad/go_web/internal/inertia"
	"github.com/antiwork/gumroad/go_web/internal/pages"
	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/sidekiq"
	"github.com/antiwork/gumroad/go_web/internal/storage"
	"github.com/antiwork/gumroad/go_web/internal/vite"
	"github.com/antiwork/gumroad/go_web/internal/web"
)

// Cache is Rails.cache, as railscache.Store reads and writes it.
type Cache interface {
	Read(ctx context.Context, key string) (any, bool, error)
	Write(ctx context.Context, key string, value any, expiresIn time.Duration) error
}

// PageConfig is what rendering reads besides Config.
type PageConfig struct {
	Layout  *inertia.Layout
	CSP     web.CSP
	Shared  *pages.Shared
	Avatars *storage.Avatars
	// Cache is Rails.cache and Redis $redis.
	Cache Cache
	Redis redis.Cmdable
	GeoIP *geoip.Reader
	// Flag is a Flipper flag by name.
	Flag func(name string) *flipper.Flag
	// CDNMap is CDN_URL_MAP in order, and PublicStorageURL the public service's object URL
	// prefix, "https://<bucket>.s3.amazonaws.com/".
	CDNMap           [][2]string
	PublicStorageURL string
	// CalendarHref is vite_asset_path("components/ui/Calendar.tsx"), "" when the manifest
	// lacks it.
	CalendarHref string
	// Search is EsClient; nil leaves what needs it to Rails.
	Search *elastic.Client
	// Sidekiq pushes jobs; nil leaves a page that enqueues one to Rails.
	Sidekiq *sidekiq.Client
	// OGNamespace is FACEBOOK_OG_NAMESPACE, and RecaptchaSiteKey FollowRecaptcha.site_key.
	OGNamespace, RecaptchaSiteKey string
	NewNonce                      func() string
	// GumroadAdminID is GUMROAD_ADMIN_ID, who writes payout setup notes; 0 leaves a page that
	// reads them to Rails.
	GumroadAdminID int64
	// CustomHTMLAnalytics is vite_typescript_tag("custom_html_analytics"); nil leaves a custom
	// HTML product page to Rails.
	CustomHTMLAnalytics *vite.Tags
}

// cdnURL is cdn_url_for.
func (pc *PageConfig) cdnURL(s string) string {
	for _, m := range pc.CDNMap {
		s = strings.ReplaceAll(s, m[0], m[1])
	}
	return s
}

// render is LinksController#prepare_product_page and #show for a signed-out visitor, or one
// signed in with no part in the product, then the after_actions. Everything is read before
// anything is written.
func (h *handler) render(w http.ResponseWriter, p *page, prod *product) error {
	pc, ctx := h.c.Page, p.Ctx
	// show sends a coffee product to /coffee, which renders it. Of the before_actions left,
	// prepare_product_page only sets meta tags and set_x_robots_tag_header marks a code;
	// wanted and native are declined params.
	if prod.nativeType == "coffee" {
		if p.urlCode != "" {
			w.Header().Set("X-Robots-Tag", "noindex")
		}
		return h.ctl.Redirect(w, p.Visit, "/coffee")
	}
	if reason, err := h.unportedShape(ctx, p, prod); err != nil || reason != "" {
		return firstErr(err, fallback(reason))
	}
	// The share blocks' checks that need no query come first.
	if _, ok := pages.Locale(p.Req.Header("Accept-Language")); !ok {
		return fallback("shared props")
	}
	if _, err := pages.FlashProps(p.Session); err != nil {
		return fallback("shared props")
	}
	if err := h.loadViewer(p, prod); err != nil {
		return err
	}

	v, err := h.loadView(ctx, p, prod)
	if err != nil {
		return err
	}
	nonce := pc.NewNonce()
	meta, err := h.productMeta(p, prod, v)
	if err != nil {
		return err
	}
	shared, err := pc.Shared.SignedOut(ctx, pages.Request{
		Req: p.Req, Session: p.Session, CSRFToken: p.MaskedCSRFToken(), ScriptNonce: nonce, Title: meta.PageTitle(h.c.Meta.Title),
	})
	if errors.Is(err, pages.ErrUnported) {
		return fallback("shared props")
	}
	if err != nil {
		return err
	}
	if p.viewer != nil && v.discount.listed {
		// Default codes are evaluated for the buyer, whose purchases they can count.
		return fallback("signed-in offer code")
	}
	// The share blocks in order: the signed-in one follows detected_buyer_currency's, and
	// LinksController's own MobileAppWebView share comes last.
	props := shared.Sym("detected_buyer_currency", nullableString(v.detectedCurrency))
	if u := p.viewer; u != nil {
		props.Sym("logged_in_user", u.loggedIn).Sym("current_seller", u.currentSeller).
			Sym("current_user", u.currentUser).Sym("prompt_passkey_setup", u.promptPasskey)
	}
	props.Sym("is_mobile_app_web_view", p.Session.Get("mobile_app_web_view") == true)
	h.productProps(props, p, prod, v)
	props.Merge(h.sectionsProps(p, v))
	component := productComponent
	if storefront(p) {
		component = storefrontComponent
	}
	props.Sym("sections", v.sections).Sym("main_section_index", v.mainSectionIndex)

	// as_embed is a declined param.
	body := pc.Layout.Render(inertia.Document{
		Component: component, URL: p.Req.FullPath(), Props: props, Meta: meta,
		UserAgent: p.Req.Header("User-Agent"), BodyID: "product_page",
		DesignSettings: pc.Shared.DesignSettingsJSON(), UserAgentInfo: pages.UserAgentInfoJSON(pages.Request{Req: p.Req, Session: p.Session}),
	})

	if !p.DryRun {
		if p.warmReputation {
			// Each command has the client's own timeout. A deadline across them could stop between
			// queue.lua and the handoff, leaving a digest no later push or reaper clears.
			if _, _, err := pc.Sidekiq.PushUntilExecuted(context.WithoutCancel(ctx), warmReputationJob, p.seller.id); err != nil {
				web.Logger(p.Req.HTTP).Warn("reputation refresh push failed", "error", err.Error())
				return fallback("reputation refresh push")
			}
		}
		h.flushCacheWrites(ctx, p)
	}
	if err := h.ctl.Finish(w, p.Visit); err != nil {
		return err
	}
	hdr := w.Header()
	if !prod.alive() || p.urlCode != "" {
		hdr.Set("X-Robots-Tag", "noindex")
	}
	hdr.Set("Content-Security-Policy", pc.CSP.Header(nonce))
	hdr.Set("Link", pc.Layout.LinkHeader())
	rails.RenderInertiaHTML(w, p.Req, body)
	return nil
}

// view is everything the page reads beyond the product and seller rows.
type view struct {
	productJSON, sellerJSON jsonData
	avatarURL               string
	ip                      string
	geo                     *geoip.Result
	detectedCurrency        *string
	prices                  prices
	priceCents              *int64
	covers                  []*cover
	thumbnailURL            any
	files                   []productFile
	reviewStat              *reviewStat
	reputationEnabled       bool
	snapshotReputation      any
	profileReputation       any
	quantityRemaining       any
	descriptionHTML         any
	descriptionPresent      bool
	plaintextDescription    string
	structuredDescription   *string
	fileSummaries           *rails.RHash
	attributes              []any
	thirdPartyAnalytics     bool
	showRatingsFilter       bool
	youtubeChannelID        any
	// recaptchaSiteKey is FollowRecaptcha.site_key when FollowRecaptcha.required?, else nil.
	recaptchaSiteKey any
	customStyles     string
	fontPreload      bool
	mainSectionIndex any
	refundPolicy     any
	currency         *currencyDisplay
	// localBuyer is the buyer currency a local price may show in, before settlement checks.
	localBuyer      *string
	variants        *variants
	collaborator    any
	salesCount      any
	recurrences     *recurrences
	tierRecurrences map[string]bool
	installmentPlan any
	preorder        any
	publicFiles     []any
	bundle          *bundle
	discount        *offerDiscount
	// ppp is ppp_details.
	ppp *pppDetails
	// sections are the product's own, or the storefront's catalog when they render none.
	sections []any
	// wishlists are the signed-in visitor's, as product_props lists them.
	wishlists []any
}

func (h *handler) loadView(ctx context.Context, p *page, prod *product) (*view, error) {
	pc, seller := h.c.Page, p.seller
	v := &view{}
	var ok bool
	if v.productJSON, ok = parseJSONData(prod.jsonData); !ok {
		return nil, fallback("product json_data")
	}
	if v.sellerJSON, ok = parseJSONData(seller.jsonData); !ok {
		return nil, fallback("seller json_data")
	}
	// These go into the props as stored; anything but a scalar is Rails'.
	for _, key := range []string{"custom_button_text_option", "custom_summary", "custom_view_content_button_text", "main_section_index"} {
		if !jsonScalar(v.productJSON.get(key)) {
			return nil, fallback("product json_data " + key)
		}
	}
	if !jsonScalar(v.sellerJSON.get("tiktok_pixel_id")) {
		return nil, fallback("seller json_data")
	}
	v.ip, _ = p.Req.RemoteIP()
	v.geo = h.lookup(v.ip)
	v.detectedCurrency = buyerCurrencyForCountry(countryCode(v.geo))

	// User#avatar_url, the page's own for a featured product.
	var err error
	if p.parent != nil {
		v.avatarURL = p.parent.avatarURL
	} else if v.avatarURL, err = h.avatarURL(ctx, seller.id); err != nil {
		return nil, err
	}

	if v.prices, err = h.loadPrices(ctx, prod); err != nil {
		return nil, err
	}
	// Link#price_cents.
	v.priceCents = v.prices.buy
	if prod.rentOnly() {
		v.priceCents = v.prices.rental
	}
	if v.priceCents == nil && prod.customizablePrice.Bool && !prod.is(productIsRecurringBilling) {
		// pwyw_default_price_cents calls zero? on the nil price, and Rails raises; it returns
		// before that for a membership.
		return nil, fallback("no price")
	}
	if v.discount, err = h.loadOfferDiscount(ctx, p, prod); err != nil {
		return nil, err
	}
	pppPrice, err := h.loadPPP(ctx, p, prod, v)
	if err != nil {
		return nil, err
	}
	// displayed_price_cents: the discounted price, or PPP's when that's lower.
	displayed := v.priceCents
	if displayed != nil && v.discount.code != nil {
		d := v.discount.discountedCents(*displayed)
		displayed = &d
	}
	if displayed != nil && pppPrice != nil && *pppPrice < *displayed {
		displayed = pppPrice
	}
	if v.localBuyer, err = h.localCurrencyBuyer(p, v); err != nil {
		return nil, err
	}
	if v.localBuyer != nil {
		if v.currency, err = h.currencyDisplayFor(p, prod, p.hasInstallmentPlan, *v.localBuyer, displayed); err != nil {
			return nil, err
		}
	}
	if c := v.currency; c != nil && *displayed < *v.priceCents {
		c.setOriginal(*v.priceCents, prod.productCurrency())
	}
	if v.installmentPlan, err = h.installmentPlanProps(ctx, p, prod); err != nil {
		return nil, err
	}
	if v.preorder, err = h.preorderProps(ctx, prod); err != nil {
		return nil, err
	}
	if v.recurrences, err = h.loadRecurrences(ctx, prod, v.prices); err != nil {
		return nil, err
	}
	if prod.is(productIsTieredMembership) {
		if v.tierRecurrences, err = tierRecurrences(v.prices); err != nil {
			return nil, err
		}
	}
	if v.covers, err = h.loadCovers(ctx, p, prod.id); err != nil {
		return nil, err
	}
	if v.thumbnailURL, err = h.thumbnailURL(ctx, prod.id); err != nil {
		return nil, err
	}
	if v.files, err = h.aliveProductFiles(ctx, prod.id); err != nil {
		return nil, err
	}
	if v.reviewStat, err = h.loadReviewStat(ctx, prod.id); err != nil {
		return nil, err
	}
	if err := h.loadReputation(ctx, p, prod, v); err != nil {
		return nil, err
	}
	if v.variants, err = h.loadVariants(ctx, prod); err != nil {
		return nil, err
	}
	if v.collaborator, err = h.collaboratorByline(ctx, p, prod); err != nil {
		return nil, err
	}
	if v.bundle, err = h.loadBundle(ctx, p, prod); err != nil {
		return nil, err
	}
	if v.quantityRemaining, err = h.remainingForSaleCount(ctx, prod, v.variants, v.bundle.quantityLeft); err != nil {
		return nil, err
	}
	if err := h.loadDescription(ctx, prod, v); err != nil {
		return nil, err
	}
	if v.refundPolicy, err = h.loadRefundPolicy(ctx, prod); err != nil {
		return nil, err
	}
	v.publicFiles = []any{}
	if p.hasPublicFiles {
		if v.publicFiles, err = h.publicFilesProps(ctx, prod.id); err != nil {
			return nil, err
		}
	}
	if v.fileSummaries, err = h.fileSummaries(ctx, prod, v.files, v.variants); err != nil {
		return nil, err
	}
	if v.attributes, err = attributesProps(v.productJSON, prod, v.files); err != nil {
		return nil, err
	}
	if v.thirdPartyAnalytics, err = h.hasThirdPartyAnalytics(ctx, prod); err != nil {
		return nil, err
	}
	v.wishlists = h.viewerWishlists(p, prod)
	if recaptchaRequired(seller, pc.RecaptchaSiteKey) {
		v.recaptchaSiteKey = pc.RecaptchaSiteKey
	}
	// Past here only the page reads: product_props leaves the sections and the profile alone.
	if p.parent != nil {
		return v, nil
	}
	if v.showRatingsFilter, err = h.exists(ctx, "SELECT 1 FROM links WHERE links.user_id = ? AND links.purchase_disabled_at IS NULL"+
		" AND links.banned_at IS NULL AND links.deleted_at IS NULL AND (links.flags & ?) != 0 LIMIT 1", seller.id, productDisplayReviews); err != nil {
		return nil, err
	}
	var channel sql.NullString
	err = h.c.DB.QueryRowContext(ctx, "SELECT channel_id FROM user_youtube_identities WHERE user_id = ? LIMIT 1", seller.id).Scan(&channel)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}
	v.youtubeChannelID = nullString(channel)
	if err := h.loadCustomStyles(ctx, p, v); err != nil {
		return nil, err
	}
	sections, err := h.listProductSections(p, prod, v)
	if err != nil {
		return nil, err
	}
	// Last: Elasticsearch searches are the costliest reads, and anything above may still fall back.
	if err := h.loadSalesCount(ctx, p, prod, v); err != nil {
		return nil, err
	}
	if v.sections, err = h.renderProductSections(p, sections, v.localBuyer); err != nil {
		return nil, err
	}
	v.mainSectionIndex = int64(0)
	if raw, ok := v.productJSON.present("main_section_index"); ok {
		v.mainSectionIndex = raw
	}
	// show_storefront_catalog?
	if storefront(p) && len(v.sections) == 0 {
		if v.sections, err = h.loadCatalog(p, prod, v.localBuyer); err != nil {
			return nil, err
		}
		v.mainSectionIndex = int64(0)
	}
	return v, nil
}

// avatarURL is User#avatar_url.
func (h *handler) avatarURL(ctx context.Context, userID int64) (string, error) {
	avatar, err := h.c.Page.Avatars.URL(ctx, userID)
	if errors.Is(err, storage.ErrUnported) {
		return "", fallback("avatar")
	}
	return avatar, err
}

func countryCode(g *geoip.Result) *string {
	if g == nil {
		return nil
	}
	return g.CountryCode
}

func nullableString(s *string) any {
	if s == nil {
		return nil
	}
	return *s
}

// pendingWrite is a Rails.cache write the render makes, held until the page is certain to
// render here.
type pendingWrite struct {
	key       string
	value     any
	expiresIn time.Duration
}

func (h *handler) flushCacheWrites(ctx context.Context, p *page) {
	for _, pw := range p.cacheWrites {
		// Rails.cache.fetch ignores a failed write too.
		if err := h.c.Page.Cache.Write(context.WithoutCancel(ctx), pw.key, pw.value, pw.expiresIn); err != nil {
			web.Logger(p.Req.HTTP).Warn("product page cache write failed", "key", pw.key, "error", err.Error())
		}
	}
}
