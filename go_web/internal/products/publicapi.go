package products

import (
	"context"
	"database/sql"
	"errors"
	"maps"
	"net/http"
	"slices"
	"strings"

	"github.com/antiwork/gumroad/go_web/internal/db"
	"github.com/antiwork/gumroad/go_web/internal/pages"
	"github.com/antiwork/gumroad/go_web/internal/rails"
)

const (
	// ProductPresenter::PublicApiProps::API_VERSION and PUBLIC_REVIEW_LIMIT.
	publicAPIVersion  = 1
	publicReviewLimit = 5
)

// errRaises is an exception Rails raises building the payload, after show's writes: the
// exceptions app's 500, without the session or the cookies.
var errRaises = errors.New("product json raises")

// renderFormat is show for any format but the page's: the same filters and side effects, then
// format.json's ProductPresenter::PublicApiProps, or format.any's e404.
func (h *handler) renderFormat(w http.ResponseWriter, p *page, prod *product) error {
	ctx := p.Ctx
	if prod.nativeType == "coffee" {
		return h.redirectCoffee(w, p, prod)
	}
	if reason, err := h.unportedShape(ctx, p, prod); err != nil || reason != "" {
		return firstErr(err, fallback(reason))
	}
	// BestOfferCodeService's buyer and create_discover_search!'s user.
	if err := h.loadViewer(p, prod); err != nil {
		return err
	}
	v, err := h.loadPublicBase(ctx, p, prod)
	if err != nil {
		return err
	}
	// show's set_favicon_meta_tags, ahead of every format.
	if v.avatarURL, err = h.avatarURL(p, p.seller.id); err != nil {
		return err
	}
	if p.wanted {
		if done, err := h.wantedRedirect(w, p, prod, v.view); err != nil || done {
			return err
		}
	}
	switch {
	case p.format != "json":
		// Only prepare_product_page's meta tags read the covers.
		keepMetaCoverWrites(p, v.covers)
		return firstErr(h.showWrites(w, p, prod, v.ip), pages.ErrNotFound)
	case !prod.priceCurrencyType.Valid:
		// currency_code's downcase raises before the covers' as_json.
		keepMetaCoverWrites(p, v.covers)
		return firstErr(h.showWrites(w, p, prod, v.ip), errRaises)
	}
	if err := h.loadPublicRest(ctx, p, prod, v); errors.Is(err, errRaises) {
		return firstErr(h.showWrites(w, p, prod, v.ip), errRaises)
	} else if err != nil {
		return err
	}
	props, err := h.publicAPIProps(p, prod, v)
	if err != nil {
		return err
	}
	if err := h.finishShow(w, p, prod, v.ip); err != nil {
		return err
	}
	w.Header().Set("Content-Security-Policy", h.c.Page.CSP.Header(""))
	rails.RenderJSON(w, p.Req, http.StatusOK, rails.EncodeJSON(props))
	return nil
}

// wantedRedirect is show's ?wanted=true checkout redirect, which comes before respond_to;
// done is false when show goes on to render.
func (h *handler) wantedRedirect(w http.ResponseWriter, p *page, prod *product, v *view) (done bool, err error) {
	if v.discount, err = h.loadOfferDiscount(p.Ctx, p, prod, v); err != nil {
		return false, err
	}
	if v.wanted, err = wantedCartItem(p, prod, v); err != nil || v.wanted == nil {
		return false, err
	}
	location, err := h.wantedCheckout(p, prod, v)
	if err != nil {
		return false, err
	}
	// As the page's redirect: the meta tags' retina pushes, and no cache writes.
	if !p.DryRun {
		if err := h.pushVariants(p.Ctx, p); err != nil {
			return false, err
		}
	}
	if err := h.trackUTMVisit(w, p, prod); err != nil {
		return false, err
	}
	if p.urlCode != "" {
		w.Header().Set("X-Robots-Tag", "noindex")
	}
	return true, h.ctl.Redirect(w, p.Visit, location)
}

// keepMetaCoverWrites keeps the cache writes of set_product_page_meta's reads: each attached
// image's url, which is the retina variant's entry or the original's.
func keepMetaCoverWrites(p *page, covers []*cover) {
	keys := map[string]bool{}
	for _, c := range covers {
		if c.isImage && c.oembed == nil {
			if key := c.urlCacheKey(); key != "" {
				keys[key] = true
			}
		}
	}
	p.cacheWrites = slices.DeleteFunc(p.cacheWrites, func(pw pendingWrite) bool { return !keys[pw.key] })
}

// publicView is what PublicApiProps reads beyond the product and seller rows.
type publicView struct {
	*view
	createdAt, updatedAt db.NullTime
	// lowestDifference is lowest_variant_price_difference_cents, and tierPrice lowest_tier_price.
	lowestDifference sql.NullInt64
	tierPrice        *tierPrice
	reviews          any
}

type tierPrice struct {
	cents      int64
	recurrence sql.NullString
}

// loadPublicBase reads what show needs before respond_to: the meta tags' covers, and for the
// wanted redirect or the payload, the prices and variants.
func (h *handler) loadPublicBase(ctx context.Context, p *page, prod *product) (*publicView, error) {
	v := &publicView{view: &view{}}
	var ok bool
	if v.productJSON, ok = parseJSONData(prod.jsonData); !ok {
		return nil, fallback("product json_data")
	}
	if !jsonScalar(v.productJSON.get("custom_summary")) {
		return nil, fallback("product json_data custom_summary")
	}
	v.ip, _ = p.Req.RemoteIP()
	var err error
	if v.covers, err = h.loadCovers(ctx, p, prod.id); err != nil {
		return nil, err
	}
	if !p.wanted && p.format != "json" {
		return v, nil
	}
	if v.prices, err = h.loadPrices(ctx, prod); err != nil {
		return nil, err
	}
	v.priceCents = v.prices.buy
	if prod.rentOnly() {
		v.priceCents = v.prices.rental
	}
	if v.recurrences, err = h.loadRecurrences(ctx, prod, v.prices); err != nil {
		return nil, err
	}
	if prod.is(productIsTieredMembership) {
		if v.tierRecurrences, err = tierRecurrences(v.prices); err != nil {
			return nil, err
		}
	}
	if v.variants, err = h.loadVariants(ctx, prod); err != nil {
		return nil, err
	}
	return v, nil
}

// loadPublicRest reads the rest of the payload. errRaises is a review Rails raises on, which
// it meets before cached_sales_count.
func (h *handler) loadPublicRest(ctx context.Context, p *page, prod *product, v *publicView) error {
	var err error
	if v.thumbnailURL, err = h.thumbnailURL(ctx, prod.id); err != nil {
		return err
	}
	if v.files, err = h.aliveProductFiles(ctx, prod.id); err != nil {
		return err
	}
	if v.reviewStat, err = h.loadReviewStat(ctx, prod.id); err != nil {
		return err
	}
	if v.bundle, err = h.loadBundle(ctx, p, prod); err != nil {
		return err
	}
	if v.quantityRemaining, err = h.remainingForSaleCount(ctx, prod, v.variants, v.bundle.quantityLeft); err != nil {
		return err
	}
	if err := h.loadDescription(ctx, prod, v.view); err != nil {
		return err
	}
	if v.refundPolicy, err = h.loadRefundPolicy(ctx, prod); err != nil {
		return err
	}
	if v.attributes, err = attributesProps(v.productJSON, prod, v.files); err != nil {
		return err
	}
	if err := h.c.DB.QueryRowContext(ctx, "SELECT links.created_at, links.updated_at FROM links WHERE links.id = ?", prod.id).
		Scan(&v.createdAt, &v.updatedAt); err != nil {
		return err
	}
	if prod.is(productIsTieredMembership) {
		if v.tierPrice, err = h.lowestTierPrice(ctx, prod, v.variants); err != nil {
			return err
		}
	} else {
		// current_base_variants.minimum: preload_product leaves the SKUs unloaded, so Rails asks
		// MySQL, with the categories' ids inline. A subquery there scans the whole table.
		categories, args := "NULL", []any{prod.id}
		if len(v.variants.categories) > 0 {
			categories, args = placeholders(len(v.variants.categories)), append(args, int64Args(v.variants.categories)...)
		}
		if err := h.c.DB.QueryRowContext(ctx, "SELECT MIN(price_difference_cents) FROM `base_variants` WHERE `base_variants`.`deleted_at` IS NULL"+
			" AND (link_id = ? OR variant_category_id IN ("+categories+"))", args...).Scan(&v.lowestDifference); err != nil {
			return err
		}
	}
	if v.reviews, err = h.publicReviews(ctx, p, prod); err != nil {
		return err
	}
	// Last: the Elasticsearch count is the costliest read.
	return h.loadSalesCount(ctx, p, prod, v.view)
}

// lowestTierPrice is lowest_tier_price over the tiers a new buyer can buy, else every tier, in
// Rails' own statement: it breaks no price ties, so MySQL's plan for the same text does.
func (h *handler) lowestTierPrice(ctx context.Context, prod *product, vs *variants) (*tierPrice, error) {
	duration, _ := prod.subscriptionDurationName()
	tp := &tierPrice{recurrence: sql.NullString{String: duration, Valid: true}}
	ids := variantIDs(offeredTiers(vs.tiers))
	if len(ids) == 0 {
		return tp, nil
	}
	// No row leaves default_tier's built price, or a new one: 0 at the subscription duration.
	err := scanNamed(ctx, h.c.DB, func(cols map[string]any) func() {
		cols["price_cents"], cols["recurrence"] = &tp.cents, &tp.recurrence
		return func() {}
	}, "SELECT `prices`.* FROM `prices` WHERE `prices`.`variant_id` IN ("+placeholders(len(ids))+") AND `prices`.`deleted_at` IS NULL"+
		" AND ((`prices`.`flags` & 1 = 0)) ORDER BY price_cents asc LIMIT 1", int64Args(ids)...)
	return tp, err
}

// publicAPIProps is PublicApiProps#props, in its key order.
func (h *handler) publicAPIProps(p *page, prod *product, v *publicView) (*rails.RHash, error) {
	priceFormatted, err := priceFormattedVerbose(prod, v)
	if err != nil {
		return nil, err
	}
	root := h.sellerCustomDomainURL(p)
	if p.productDomain {
		root = h.userProfileURL(p.seller)
	}
	seller := bylineProps(p.seller, v.avatarURL, root)
	if seller == nil {
		return nil, fallback("seller byline")
	}
	covers := make([]any, len(v.covers))
	for i, c := range v.covers {
		covers[i] = c.json()
	}
	var ratings any
	if prod.is(productDisplayReviews) {
		ratings = v.reviewStat.ratingStats()
	}
	var suggested any
	if prod.customizablePrice.Bool {
		suggested = nullInt(prod.suggestedPriceCents)
	}
	var recurrences any
	if prod.is(productIsRecurringBilling) {
		recurrences = v.recurrences.props()
	}
	permalink := prod.generalPermalink()
	return rails.NewRHash().
		Sym("api_version", publicAPIVersion).
		Sym("id", h.c.IDs.Encrypt(prod.id)).
		Sym("permalink", permalink).
		Sym("name", prod.name).
		Sym("native_type", prod.nativeType).
		Sym("url", h.c.Env.ProductLongURL(sellerUsername(p.seller), permalink)).
		Sym("thumbnail_url", v.thumbnailURL).
		Sym("created_at", v.createdAt.OrNil()).
		Sym("updated_at", v.updatedAt.OrNil()).
		Sym("seller", seller).
		Sym("price_cents", intOrNil(v.priceCents)).
		Sym("currency_code", rails.Downcase(prod.priceCurrencyType.String)).
		Sym("price_formatted", priceFormatted).
		Sym("is_pay_what_you_want", prod.customizablePrice.Bool).
		Sym("suggested_price_cents", suggested).
		Sym("is_recurring_billing", prod.is(productIsRecurringBilling)).
		Sym("is_tiered_membership", prod.is(productIsTieredMembership)).
		Sym("recurrences", recurrences).
		Sym("free_trial", freeTrialProps(prod)).
		Sym("description_html", v.descriptionHTML).
		Sym("summary", presence(v.productJSON.get("custom_summary"))).
		Sym("covers", covers).
		Sym("attributes", v.attributes).
		Sym("ratings", ratings).
		Sym("reviews", v.reviews).
		Sym("sales_count", v.salesCount).
		Sym("options", h.optionsProps(prod, v.variants, v.tierRecurrences)).
		Sym("quantity_remaining", v.quantityRemaining).
		Sym("is_quantity_enabled", prod.is(productQuantityEnabled)).
		Sym("is_sales_limited", prod.maxPurchaseCount.Valid && prod.maxPurchaseCount.Int64 != 0).
		Sym("is_published", !prod.draft.Bool && prod.alive()).
		Sym("is_physical", prod.is(productIsPhysical)).
		Sym("refund_policy", v.refundPolicy), nil
}

// priceFormattedVerbose is Link#price_formatted_verbose: display_price_cents, a + where
// show_customizable_price_indicator?, and the display recurrence's label.
func priceFormattedVerbose(prod *product, v *publicView) (string, error) {
	cents, customizable := v.lowestDifference.Int64, prod.customizablePrice.Bool
	duration, _ := prod.subscriptionDurationName()
	recurrence := duration
	if t := v.tierPrice; t != nil {
		offered := offeredTiers(v.variants.tiers)
		cents, recurrence = t.cents, t.recurrence.String
		customizable = len(offered) > 1 || slices.ContainsFunc(offered, func(o *variantOption) bool { return o.customizablePrice.Bool }) ||
			len(offered) == 1 && len(offered[0].buyPrices) > 1
	} else if v.priceCents != nil {
		cents += *v.priceCents
	}
	formatted, ok := displayPrice(cents, prod.priceCurrencyType.String)
	if !ok {
		return "", fallback("price formatted currency")
	}
	if customizable {
		formatted += "+"
	}
	if prod.is(productIsRecurringBilling) {
		// recurrence_label: nil for a blank or unknown recurrence.
		formatted += " " + recurrenceLongIndicators[recurrence]
	}
	return formatted, nil
}

// displayPrice is format_price(MoneyFormatter.format(cents, currency, no_cents_if_whole: true,
// symbol: true)). ok is false for a currency Money knows that the pricing table doesn't.
func displayPrice(cents int64, currency string) (string, bool) {
	code := rails.Downcase(currency)
	f, priced := currencies[code]
	if !priced {
		if moneyCurrencies[code] {
			return "", false
		}
		// MoneyFormatter's soft fail: the amount as dollars without the symbol, then the code.
		number := moneyNumber(cents, false)
		if iso := strings.ToUpper(currency); iso != "" {
			number += " " + iso
		}
		return number, true
	}
	// Money's sign follows a leading symbol and leads a trailing one.
	price := f.prefix + moneyNumber(cents, f.singleUnit) + f.suffix
	if price == "$0.99" {
		return "99¢", true
	}
	return price, true
}

// moneyNumber is Money#format's number with no_cents_if_whole and en's separators.
func moneyNumber(cents int64, singleUnit bool) string {
	sign := ""
	if cents < 0 {
		sign, cents = "-", -cents
	}
	if singleUnit {
		return sign + groupThousands(itoa(cents))
	}
	number := groupThousands(itoa(cents / 100))
	if c := cents % 100; c != 0 {
		number += "." + itoa(c/10) + itoa(c%10)
	}
	return sign + number
}

// publicReviews is public_reviews_props: the top alive reviews visible on the product page,
// as product_review_props sliced to what the payload shows, with its preloads' statements.
func (h *handler) publicReviews(ctx context.Context, p *page, prod *product) (any, error) {
	if !prod.is(productDisplayReviews) {
		return nil, nil
	}
	type review struct {
		id                 int64
		rating, purchaseID sql.NullInt64
		message            sql.NullString
		anonymous          sql.NullBool
		createdAt          db.NullTime
	}
	// visible_on_product_page's join repeats a review for each approved video, as Rails does.
	var reviews []*review
	err := scanNamed(ctx, h.c.DB, func(cols map[string]any) func() {
		r := &review{}
		cols["id"], cols["rating"], cols["message"], cols["anonymous"] = &r.id, &r.rating, &r.message, &r.anonymous
		cols["created_at"], cols["purchase_id"] = &r.createdAt, &r.purchaseID
		return func() { reviews = append(reviews, r) }
	}, "SELECT `product_reviews`.* FROM `product_reviews` LEFT OUTER JOIN `product_review_videos` ON `product_review_videos`.`deleted_at` IS NULL"+
		" AND `product_review_videos`.`approval_status` = 'approved' AND `product_review_videos`.`product_review_id` = `product_reviews`.`id`"+
		" WHERE `product_reviews`.`link_id` = ? AND `product_reviews`.`deleted_at` IS NULL AND (product_reviews.has_message = true"+
		" OR product_review_videos.id IS NOT NULL) ORDER BY `product_reviews`.`rating` DESC, `product_reviews`.`created_at` DESC,"+
		" `product_reviews`.`id` DESC LIMIT ?", prod.id, publicReviewLimit)
	if err != nil || len(reviews) == 0 {
		return []any{}, err
	}
	var ids, purchaseIDs []int64
	for _, r := range reviews {
		if !slices.Contains(ids, r.id) {
			ids = append(ids, r.id)
		}
		if r.purchaseID.Valid && !slices.Contains(purchaseIDs, r.purchaseID.Int64) {
			purchaseIDs = append(purchaseIDs, r.purchaseID.Int64)
		}
	}
	purchases := map[int64]*visitorPurchase{}
	if len(purchaseIDs) > 0 {
		if err := scanNamed(ctx, h.c.DB, func(cols map[string]any) func() {
			vp := &visitorPurchase{}
			cols["id"], cols["flags"], cols["purchaser_id"], cols["street_address"] = &vp.id, &vp.flags, &vp.purchaserID, &vp.streetAddress
			return func() { purchases[vp.id] = vp }
		}, "SELECT `purchases`.* FROM `purchases` WHERE `purchases`.`id` IN ("+placeholders(len(purchaseIDs))+")", int64Args(purchaseIDs)...); err != nil {
			return nil, err
		}
	}
	// The has_one preloads keep each review's first row, in their statements' order.
	responses := map[int64]*sql.NullString{}
	if err := scanNamed(ctx, h.c.DB, func(cols map[string]any) func() {
		var id int64
		message := &sql.NullString{}
		cols["product_review_id"], cols["message"] = &id, message
		return func() {
			if responses[id] == nil {
				responses[id] = message
			}
		}
	}, "SELECT `product_review_responses`.* FROM `product_review_responses` WHERE `product_review_responses`.`product_review_id` IN ("+
		placeholders(len(ids))+")", int64Args(ids)...); err != nil {
		return nil, err
	}
	videos := map[int64]int64{}
	if err := scanNamed(ctx, h.c.DB, func(cols map[string]any) func() {
		var id, reviewID int64
		cols["id"], cols["product_review_id"] = &id, &reviewID
		return func() {
			if _, seen := videos[reviewID]; !seen {
				videos[reviewID] = id
			}
		}
	}, "SELECT `product_review_videos`.* FROM `product_review_videos` WHERE `product_review_videos`.`product_review_id` IN ("+
		placeholders(len(ids))+") AND `product_review_videos`.`deleted_at` IS NULL AND `product_review_videos`.`approval_status` = 'approved'"+
		" ORDER BY `product_review_videos`.`created_at` DESC", int64Args(ids)...); err != nil {
		return nil, err
	}
	if len(videos) > 0 {
		// video_props reads the video's file, and nil.thumbnail_url raises.
		videoIDs := slices.Collect(maps.Values(videos))
		filed, err := h.scanIDs(ctx, "SELECT DISTINCT video_files.record_id AS id FROM video_files WHERE video_files.record_type = 'ProductReviewVideo'"+
			" AND video_files.record_id IN ("+placeholders(len(videoIDs))+")", int64Args(videoIDs)...)
		if err != nil {
			return nil, err
		}
		if len(filed) != len(videoIDs) {
			return nil, errRaises
		}
	}
	out := make([]any, len(reviews))
	for i, r := range reviews {
		purchase := purchases[r.purchaseID.Int64]
		if purchase == nil || !r.createdAt.Valid {
			// purchase.purchaser and created_at.iso8601 raise on nil.
			return nil, errRaises
		}
		accountName, err := h.raterAccountName(p, purchase)
		if err != nil {
			return nil, err
		}
		// shows_account_identity?, else image_url's default avatar.
		avatar, name := h.c.Page.Avatars.AssetHost+"/images/gumroad-default-avatar-5.png", any("Anonymous")
		if !r.anonymous.Bool && rails.Present(accountName) {
			if avatar, err = h.avatarURL(p, purchase.purchaserID.Int64); err != nil {
				return nil, err
			}
			name = accountName
		}
		var response any
		if m := responses[r.id]; m != nil {
			response = rails.NewRHash().Sym("message", nullString(*m))
		}
		out[i] = rails.NewRHash().
			Sym("id", h.c.IDs.Encrypt(r.id)).
			Sym("rating", nullInt(r.rating)).
			Sym("message", nullString(r.message)).
			Sym("rater", rails.NewRHash().Sym("avatar_url", avatar).Sym("name", name)).
			Sym("created_at", r.createdAt.Time).
			Sym("response", response)
	}
	return out, nil
}
