package downloads

import (
	"context"
	"database/sql"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/delivery"
	"github.com/antiwork/gumroad/go_web/internal/inertia"
	"github.com/antiwork/gumroad/go_web/internal/pages"
	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/sidekiq"
	"github.com/antiwork/gumroad/go_web/internal/storage"
	"github.com/antiwork/gumroad/go_web/internal/viewer"
	"github.com/antiwork/gumroad/go_web/internal/web"
)

// PageConfig is what the full download page reads besides Config. Without it every full
// page goes to Rails.
type PageConfig struct {
	Layout  *inertia.Layout
	CSP     web.CSP
	Shared  *pages.Shared
	Avatars *storage.Avatars
	Content delivery.ContentConfig
	// EmailDigestKey is OBFUSCATE_IDS_CIPHER_KEY, and DropboxAPIKey DROPBOX_PICKER_API_KEY.
	EmailDigestKey, DropboxAPIKey string
	// IOSAppID and AndroidBundleID are app_store_info.rb's.
	IOSAppID, AndroidBundleID string
	// NewNonce is SecureHeaders' script nonce: SecureRandom.base64(32).
	NewNonce func() string
	// Sidekiq pushes the page's jobs; without it a page that enqueues one goes to Rails.
	Sidekiq *sidekiq.Client
	// BuyerCurrency is what seller_analytics reads; nil leaves pages with it to Rails.
	BuyerCurrency BuyerCurrency
	// Viewers loads the signed-in visitor and the signed-in share; nil leaves signed-in pages
	// to Rails.
	Viewers *viewer.Loader
}

// pageWriteTimeout bounds the after_actions' writes, which outlive a client that leaves.
const pageWriteTimeout = 5 * time.Second

// renderPage is download_page's full render: the action, render(inertia:), then the
// after_actions in Rails' order (the last declared first). Everything is read before
// anything is written, so a fallback it returns is still safe.
func (h *handler) renderPage(w http.ResponseWriter, p *page, u *urlRedirect) error {
	pc := h.c.Pages
	switch {
	case p.Auth.LoggedInUser() != nil && pc.Viewers == nil:
		return fallback("signed in")
	case p.purchase == nil:
		return fallback("no purchase")
	case u.importedCustomerID != nil:
		// The license prop would create the imported customer's license.
		return fallback("imported customer")
	case p.Req.Param("folder_id") != nil:
		// The view event stores params[:folder_id] in its json_data.
		return fallback("param folder_id")
	}
	// The share blocks' checks that need no query come first.
	if _, ok := pages.Locale(p.Req.Header("Accept-Language")); !ok {
		return fallback("shared props")
	}
	if _, err := pages.FlashProps(p.Session); err != nil {
		return fallback("shared props")
	}
	d, err := h.loadPageData(p.Ctx, p)
	if err != nil {
		return err
	}
	pp, err := h.loadPurchaseProps(p.Ctx, p, d)
	if err != nil {
		return err
	}
	var v *viewer.Viewer
	if p.Auth.LoggedInUser() != nil {
		if v, err = pc.Viewers.Load(p.Ctx, p.Req, p.Session, p.Auth); err != nil {
			return err
		}
		if len(v.AvatarResizes) > 0 {
			// avatar_url would enqueue GenerateAvatarVariantJob, which this page doesn't push.
			return fallback("avatar")
		}
	}
	addToLibrary, err := addToLibraryOption(p, d, v)
	if err != nil {
		return err
	}
	content := delivery.NewPage(p.Ctx, h.c.DB, u.delivery(), h.c.IDs)
	owner, err := content.Owner()
	if err != nil {
		return unported(err)
	}
	if owner.SellerID == nil {
		return fallback("no seller")
	}
	lc, err := h.planLifecycle(p.Ctx, content, u)
	if err != nil {
		return err
	}
	rich, err := content.RichContentPages()
	if err != nil {
		return unported(err)
	}
	if rich.JSON == nil || rich.MayHavePosts {
		return fallback("posts")
	}
	var kindleEmail any
	if v != nil {
		kindleEmail = nullableString(v.User.KindleEmail)
		// video_transcoding_info is the seller's own: it reads has_been_transcoded?.
		if v.User.ID == *owner.SellerID && len(lc.videos) > 0 {
			return fallback("seller's video")
		}
	}
	items, err := content.ContentItems(delivery.ContentRedirect{
		Token: u.token, Rental: u.flags&urlRedirectIsRental != 0, ReferencedProductID: owner.ReferencedProductID, KindleEmail: kindleEmail,
	}, pc.Content)
	if err != nil {
		return unported(err)
	}
	lastPage, err := d.lastContentPageID()
	if err != nil {
		return err
	}
	discord, err := h.discordProp(p.Ctx, p.purchase, d)
	if err != nil {
		return err
	}
	communityChat, err := h.communityChatURL(p.Ctx, d, owner.ReferencedProductID, v != nil)
	if err != nil {
		return err
	}
	avatar, resize, err := pc.Avatars.URL(p.Ctx, *owner.SellerID)
	if errors.Is(err, storage.ErrUnported) || resize {
		return fallback("avatar")
	}
	if err != nil {
		return err
	}

	nonce := pc.NewNonce()
	title := owner.Name
	if title.String == "Untitled" {
		title = owner.ReferencedName
	}
	meta := h.metaTags(p)
	// set_download_page_meta_tags: the favicon replaces the defaults in place.
	meta.Set(inertia.NewMetaTag("link", "shortcut-icon", "", inertia.Attr{Key: "rel", Value: "shortcut icon"}, inertia.Attr{Key: "href", Value: avatar}))
	meta.Set(inertia.NewMetaTag("link", "apple-touch-icon", "", inertia.Attr{Key: "rel", Value: "apple-touch-icon"}, inertia.Attr{Key: "href", Value: avatar}))
	if !title.Valid {
		return fallback("nil title")
	}
	meta.Set(inertia.NewMetaTag("", "", "", inertia.Attr{Key: "title", Value: title.String}))
	downloadURL := h.c.Env.Protocol + "://" + h.c.Env.Domain + "/d/" + u.token
	meta.Set(inertia.NewMetaTag("", "", "", inertia.Attr{Key: "name", Value: "apple-itunes-app"},
		inertia.Attr{Key: "content", Value: "app-id=" + pc.IOSAppID + ", app-argument=" + downloadURL}))

	shared, err := pc.Shared.SignedOut(p.Ctx, pages.Request{
		Req: p.Req, Session: p.Session, CSRFToken: p.MaskedCSRFToken(), ScriptNonce: nonce, Title: meta.PageTitle(h.c.Meta.Title),
	})
	if errors.Is(err, pages.ErrUnported) {
		return fallback("shared props")
	}
	if err != nil {
		return err
	}

	if v != nil {
		// The signed-in share block follows the ones every page has.
		shared.Sym("logged_in_user", v.LoggedInUser).Sym("current_seller", v.CurrentSeller).
			Sym("current_user", v.CurrentUser).Sym("prompt_passkey_setup", v.PromptPasskeySetup)
	}

	pu := p.purchase
	var variantID any
	if owner.VariantID != nil {
		variantID = h.c.IDs.Encrypt(*owner.VariantID)
	}
	permalink := d.uniquePermalink.String
	if rails.Present(d.customPermalink.String) {
		permalink = d.customPermalink.String
	}
	purchaseID := h.c.IDs.Encrypt(pu.id)
	protocolRoot := h.c.Env.Protocol + "://" + h.c.Env.RootDomain

	props := shared.
		Sym("content", rails.NewRHash().
			Sym("license", d.license).
			Sym("content_items", items).
			Sym("bundle_products", []any{}).
			Sym("rich_content_pages", rich.JSON).
			Sym("last_content_page_id", lastPage).
			Sym("posts", []any{}).
			Sym("video_transcoding_info", nil).
			Sym("custom_receipt", nil).
			Sym("discord", discord).
			Sym("community_chat_url", communityChat).
			Sym("ios_app_url", "https://itunes.apple.com/app/id"+pc.IOSAppID).
			Sym("android_app_url", "https://play.google.com/store/apps/details?id="+pc.AndroidBundleID).
			Sym("download_all_button", nil)).
		Sym("product_has_third_party_analytics", d.thirdPartyAnalytics).
		Sym("seller_analytics", d.sellerAnalytics).
		Sym("terms_page_url", protocolRoot+"/terms").
		Sym("token", u.token).
		Sym("redirect_id", h.c.IDs.Encrypt(u.id)).
		Sym("purchase", rails.NewRHash().
			Sym("id", purchaseID).
			Sym("receipt_purchase_id", h.c.IDs.Encrypt(pp.receiptID)).
			Sym("email", nullableString(d.email)).
			Sym("free", d.freePurchase()).
			Sym("seller_name", d.sellerNameOrUsername()).
			Sym("email_digest", rails.EmailDigest(pc.EmailDigestKey, pu.id, d.email.String)).
			Sym("created_at", d.createdAt.OrNil()).
			Sym("is_archived", pu.flags&purchaseIsArchived != 0).
			Sym("has_invoice", pp.hasInvoice).
			Sym("product_permalink", nullableString(d.uniquePermalink)).
			Sym("product_id", h.c.IDs.Encrypt(d.productID)).
			Sym("product_name", nullableString(d.productName)).
			Sym("variant_id", variantID).
			Sym("product_long_url", h.c.Env.ProductLongURL(d.ownerUsernameOrExternalID(), permalink)).
			Sym("allows_review", d.allowsReview(pu)).
			Sym("product_available", !d.productDeleted).
			Sym("disable_reviews_after_year", d.sellerFlags&userDisablesReviewsAfterYear != 0).
			Sym("review", pp.review).
			Sym("review_account_name", d.raterAccountName(pu)).
			Sym("membership", pp.membership).
			Sym("purchase_custom_fields", pp.customFields).
			Sym("call", pp.call)).
		Sym("is_mobile_app_web_view", p.Req.Param("display") == "mobile_app").
		Sym("content_unavailability_reason_code", nil).
		Sym("add_to_library_option", addToLibrary).
		Sym("dropbox_api_key", pc.DropboxAPIKey)

	asEmbed, _ := p.Req.Params.Get("as_embed")
	body := pc.Layout.Render(inertia.Document{
		Component: component, URL: p.Req.FullPath(), Props: props, Meta: meta,
		UserAgent: p.Req.Header("User-Agent"), AsEmbed: rails.Truthy(asEmbed),
		DesignSettings: pc.Shared.DesignSettingsJSON(), UserAgentInfo: pages.UserAgentInfoJSON(pages.Request{Req: p.Req, Session: p.Session}),
	})

	// The writes, as the after_actions run: the view event, then the uses, the seen flag and
	// the confirmation cookie.
	// A dry run skips only the database writes: its cookies are what a parity check compares
	// with Rails', and it keeps none of them.
	if !p.DryRun {
		// trigger_files_lifecycle_events runs in the action, before the render and its after_actions.
		ctx, cancel := context.WithTimeout(context.WithoutCancel(p.Ctx), pageWriteTimeout)
		err := h.runLifecycle(ctx, lc)
		cancel()
		if err != nil {
			return err
		}
		if err := h.recordView(p, u, d.productID); err != nil {
			return err
		}
	}
	value := h.c.Store.Codec.Encrypt(confirmedCookie, []byte(rails.EncodeJSON(u.token)), time.Time{})
	p.Cookies = append(p.Cookies, rails.SetCookie{Name: confirmedCookie, Value: value, HTTPOnly: true}.Line(p.Secure))
	if err := h.finish(w, p); err != nil {
		return err
	}
	hdr := w.Header()
	hdr.Set("Content-Security-Policy", pc.CSP.Header(nonce))
	hdr.Set("Link", pc.Layout.LinkHeader())
	rails.RenderInertiaHTML(w, p.Req, body)
	return nil
}

// recordView is create_download_page_view_consumption_event!, then
// register_that_user_has_downloaded_product's two writes.
func (h *handler) recordView(p *page, u *urlRedirect, productID int64) error {
	ctx, cancel := context.WithTimeout(context.WithoutCancel(p.Ctx), pageWriteTimeout)
	defer cancel()
	ip, _ := p.Req.RemoteIP()
	// serialize :json_data, coder: JSON, after the folder_id and ip_address writers ran.
	jsonData := `{"folder_id":null,"ip_address":` + rails.EncodeJSON(ip) + `}`
	now := h.c.Now()
	// The model's datetime columns keep whole seconds, which Active Record truncates to.
	stamp := now.UTC().Truncate(time.Second)
	if _, err := h.c.DB.ExecContext(ctx, `INSERT INTO consumption_events (event_type, platform, url_redirect_id,
		product_file_id, purchase_id, link_id, consumed_at, json_data, created_at, updated_at)
		VALUES ('view', 'web', ?, NULL, ?, ?, ?, ?, ?, ?)`,
		u.id, p.purchase.id, productID, stamp, jsonData, stamp, stamp); err != nil {
		return err
	}
	if _, err := h.c.DB.ExecContext(ctx, "UPDATE url_redirects SET uses = COALESCE(uses, 0) + 1 WHERE id = ?", u.id); err != nil {
		return err
	}
	// mark_as_seen quotes Time.current into its SQL, microseconds and all, and MySQL rounds.
	_, err := h.c.DB.ExecContext(ctx, "UPDATE url_redirects SET flags = COALESCE(flags, 0) | ?, updated_at = ? WHERE id = ?",
		urlRedirectHasBeenSeen, now.UTC().Truncate(time.Microsecond), u.id)
	return err
}

// AddToLibraryOption's values.
const (
	addToLibraryNone   = "none"
	addToLibraryButton = "add_to_library_button"
	addToLibrarySignup = "signup_form"
)

// addToLibraryOption is common_props' add_to_library_option: a purchase without a purchaser
// offers to join the visitor's library, unless the visitor is its seller claiming it.
func addToLibraryOption(p *page, d *pageData, v *viewer.Viewer) (string, error) {
	pu := p.purchase
	if pu.purchaserID != nil {
		return addToLibraryNone, nil
	}
	if v == nil {
		return addToLibrarySignup, nil
	}
	claimed, err := claimBySeller(pu, d, v.User)
	if err != nil || claimed {
		return addToLibraryNone, err
	}
	return addToLibraryButton, nil
}

// claimBySeller is Purchase#claim_by_seller?(user) for a purchase whose purchaser is nil.
func claimBySeller(pu *purchase, d *pageData, u *viewer.User) (bool, error) {
	if d.ownerID != u.ID {
		return false, nil
	}
	if test, err := pu.testPurchase(); err != nil || test {
		return false, err
	}
	if d.purchaserIDColumn.Valid {
		// A purchaser_id whose user is gone.
		return true, nil
	}
	// casecmp? folds Unicode fully, which strings.EqualFold doesn't; past ASCII, Rails decides.
	if !ascii(d.email.String) || !ascii(u.Email.String) {
		return false, fallback("email case")
	}
	return !strings.EqualFold(d.email.String, u.Email.String), nil
}

func ascii(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] >= 0x80 {
			return false
		}
	}
	return true
}

func unported(err error) error {
	if errors.Is(err, delivery.ErrUnported) {
		return fallback("content")
	}
	return err
}

func nullableString(s sql.NullString) any {
	if !s.Valid {
		return nil
	}
	return s.String
}

func nullableInt(n sql.NullInt64) any {
	if !n.Valid {
		return nil
	}
	return n.Int64
}
