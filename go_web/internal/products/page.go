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
	"github.com/antiwork/gumroad/go_web/internal/storage"
	"github.com/antiwork/gumroad/go_web/internal/web"
)

const component = "Products/Show"

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
	// Search is EsClient; nil leaves what needs it to Rails.
	Search *elastic.Client
	// OGNamespace is FACEBOOK_OG_NAMESPACE, and RecaptchaSiteKey FollowRecaptcha.site_key.
	OGNamespace, RecaptchaSiteKey string
	NewNonce                      func() string
}

// cdnURL is cdn_url_for.
func (pc *PageConfig) cdnURL(s string) string {
	for _, m := range pc.CDNMap {
		s = strings.ReplaceAll(s, m[0], m[1])
	}
	return s
}

// render is LinksController#prepare_product_page and #show for a signed-out visitor, then
// the after_actions. Everything is read before anything is written.
func (h *handler) render(w http.ResponseWriter, p *page, prod *product) error {
	pc, ctx := h.c.Page, p.Ctx
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
	props := shared.
		Sym("detected_buyer_currency", nullableString(v.detectedCurrency)).
		Sym("is_mobile_app_web_view", p.Session.Get("mobile_app_web_view") == true)
	h.productProps(props, p, prod, v)
	props.Merge(h.sectionsProps(p, v))
	props.Sym("sections", []any{}).Sym("main_section_index", v.mainSectionIndex)

	// as_embed is a declined param.
	body := pc.Layout.Render(inertia.Document{
		Component: component, URL: p.Req.FullPath(), Props: props, Meta: meta,
		UserAgent: p.Req.Header("User-Agent"), BodyID: "product_page",
		DesignSettings: pc.Shared.DesignSettingsJSON(), UserAgentInfo: pages.UserAgentInfoJSON(pages.Request{Req: p.Req, Session: p.Session}),
	})

	if !p.DryRun {
		h.flushCacheWrites(ctx, p)
	}
	if err := h.ctl.Finish(w, p.Visit); err != nil {
		return err
	}
	hdr := w.Header()
	if !prod.alive() {
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
	recaptchaRequired       bool
	customStyles            string
	fontPreload             bool
	mainSectionIndex        any
	refundPolicy            any
	currency                *currencyDisplay
	variants                *variants
	salesCount              any
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

	// User#avatar_url.
	avatar, err := pc.Avatars.URL(ctx, seller.id)
	if errors.Is(err, storage.ErrUnported) {
		return nil, fallback("avatar")
	}
	if err != nil {
		return nil, err
	}
	v.avatarURL = avatar

	if v.priceCents, err = h.buyPriceCents(ctx, prod); err != nil {
		return nil, err
	}
	if v.priceCents == nil && prod.customizablePrice.Bool {
		// pwyw_default_price_cents calls zero? on the nil price, and Rails raises.
		return nil, fallback("no price")
	}
	if v.currency, err = h.loadCurrencyDisplay(p, prod, v); err != nil {
		return nil, err
	}
	if err := h.checkPPP(ctx, p, prod, v); err != nil {
		return nil, err
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
	for _, f := range v.files {
		if f.streamOnly() {
			return nil, fallback("stream-only files")
		}
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
	if v.quantityRemaining, err = h.remainingForSaleCount(ctx, prod, v.variants); err != nil {
		return nil, err
	}
	if err := h.loadDescription(ctx, prod, v); err != nil {
		return nil, err
	}
	if v.refundPolicy, err = h.loadRefundPolicy(ctx, prod); err != nil {
		return nil, err
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
	v.recaptchaRequired = recaptchaRequired(seller, pc.RecaptchaSiteKey)
	if err := h.loadCustomStyles(ctx, p, v); err != nil {
		return nil, err
	}
	// Last: an Elasticsearch search is the costliest read, and anything above may still fall back.
	if err := h.loadSalesCount(ctx, p, prod, v); err != nil {
		return nil, err
	}
	v.mainSectionIndex = int64(0)
	if raw, ok := v.productJSON.present("main_section_index"); ok {
		v.mainSectionIndex = raw
	}
	return v, nil
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
