package products

import (
	"context"
	"database/sql"
	"net/http"

	"github.com/antiwork/gumroad/go_web/internal/db"
	"github.com/antiwork/gumroad/go_web/internal/rails"
)

const (
	// ProductPresenter::PublicApiProps::API_VERSION and PUBLIC_REVIEW_LIMIT.
	publicAPIVersion  = 1
	publicReviewLimit = 5
)

// renderJSON is show's format.json: ProductPresenter::PublicApiProps after the same filters
// and side effects as the page, but for the reads only the page makes.
func (h *handler) renderJSON(w http.ResponseWriter, p *page, prod *product) error {
	ctx := p.Ctx
	if prod.nativeType == "coffee" {
		return h.redirectCoffee(w, p, prod)
	}
	switch {
	case p.wanted:
		return fallback("wanted json")
	case prod.is(productIsTieredMembership):
		// display_price_cents reads the tiers' own prices.
		return fallback("tiered membership json")
	}
	if reason, err := h.unportedShape(ctx, p, prod); err != nil || reason != "" {
		return firstErr(err, fallback(reason))
	}
	// create_discover_search! records the signed-in visitor.
	if err := h.loadViewer(p, prod); err != nil {
		return err
	}
	v, err := h.loadPublicView(ctx, p, prod)
	if err != nil {
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

// publicView is what PublicApiProps reads beyond the product and seller rows.
type publicView struct {
	*view
	createdAt, updatedAt db.NullTime
	// lowestDifference is lowest_variant_price_difference_cents.
	lowestDifference sql.NullInt64
	reviews          any
}

func (h *handler) loadPublicView(ctx context.Context, p *page, prod *product) (*publicView, error) {
	v := &publicView{view: &view{}}
	var ok bool
	if v.productJSON, ok = parseJSONData(prod.jsonData); !ok {
		return nil, fallback("product json_data")
	}
	if !jsonScalar(v.productJSON.get("custom_summary")) {
		return nil, fallback("product json_data custom_summary")
	}
	if !prod.priceCurrencyType.Valid {
		// price_currency_type.downcase raises.
		return nil, fallback("no price currency")
	}
	v.ip, _ = p.Req.RemoteIP()
	var err error
	if v.avatarURL, err = h.avatarURL(ctx, p.seller.id); err != nil {
		return nil, err
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
	if v.variants, err = h.loadVariants(ctx, prod); err != nil {
		return nil, err
	}
	if v.bundle, err = h.loadBundle(ctx, p, prod); err != nil {
		return nil, err
	}
	if v.quantityRemaining, err = h.remainingForSaleCount(ctx, prod, v.variants, v.bundle.quantityLeft); err != nil {
		return nil, err
	}
	if err := h.loadDescription(ctx, prod, v.view); err != nil {
		return nil, err
	}
	if v.refundPolicy, err = h.loadRefundPolicy(ctx, prod); err != nil {
		return nil, err
	}
	if v.attributes, err = attributesProps(v.productJSON, prod, v.files); err != nil {
		return nil, err
	}
	// The lowest difference is current_base_variants.minimum: preload_product leaves the SKUs
	// unloaded, so Rails asks MySQL.
	if err := h.c.DB.QueryRowContext(ctx, "SELECT links.created_at, links.updated_at, (SELECT MIN(base_variants.price_difference_cents)"+
		" FROM base_variants WHERE base_variants.deleted_at IS NULL AND (base_variants.link_id = links.id OR base_variants.variant_category_id IN"+
		" (SELECT variant_categories.id FROM variant_categories WHERE variant_categories.link_id = links.id AND variant_categories.deleted_at IS NULL)))"+
		" FROM links WHERE links.id = ?", prod.id).Scan(&v.createdAt, &v.updatedAt, &v.lowestDifference); err != nil {
		return nil, err
	}
	if v.reviews, err = h.publicReviews(ctx, p, prod); err != nil {
		return nil, err
	}
	// Last: the Elasticsearch count is the costliest read.
	if err := h.loadSalesCount(ctx, p, prod, v.view); err != nil {
		return nil, err
	}
	return v, nil
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

// priceFormattedVerbose is Link#price_formatted_verbose for a product without tiers: the
// cheapest variant's price, a + when it's pay what you want, and a membership's recurrence.
func priceFormattedVerbose(prod *product, v *publicView) (string, error) {
	cents := v.lowestDifference.Int64
	if v.priceCents != nil {
		cents += *v.priceCents
	}
	formatted, ok := formatJustPriceInCents(cents, prod.priceCurrencyType.String)
	if !ok {
		return "", fallback("price formatted")
	}
	if prod.customizablePrice.Bool {
		formatted += "+"
	}
	if prod.is(productIsRecurringBilling) {
		// unportedMembership leaves only a known subscription duration.
		duration, _ := prod.subscriptionDurationName()
		label, ok := recurrenceLongIndicators[duration]
		if !ok {
			return "", fallback("price formatted recurrence")
		}
		formatted += " " + label
	}
	return formatted, nil
}

// publicReviews is public_reviews_props: the top alive reviews visible on the product page,
// as product_review_props sliced to what the payload shows.
func (h *handler) publicReviews(ctx context.Context, p *page, prod *product) (any, error) {
	if !prod.is(productDisplayReviews) {
		return nil, nil
	}
	type review struct {
		id                 int64
		rating, purchaseID sql.NullInt64
		message, response  sql.NullString
		anonymous          sql.NullBool
		createdAt          db.NullTime
		responses          int
		purchase           *visitorPurchase
	}
	var reviews []*review
	// visible_on_product_page's left join on approved_video, whose has_one scope the join keeps.
	var video bool
	err := scanNamed(ctx, h.c.DB, func(cols map[string]any) func() {
		r := &review{}
		var videoID sql.NullInt64
		cols["id"], cols["rating"], cols["message"], cols["anonymous"] = &r.id, &r.rating, &r.message, &r.anonymous
		cols["created_at"], cols["purchase_id"], cols["video_id"] = &r.createdAt, &r.purchaseID, &videoID
		return func() {
			video = video || videoID.Valid
			reviews = append(reviews, r)
		}
	}, "SELECT product_reviews.id, product_reviews.rating, product_reviews.message, product_reviews.anonymous,"+
		" product_reviews.created_at, product_reviews.purchase_id, product_review_videos.id AS video_id FROM product_reviews"+
		" LEFT OUTER JOIN product_review_videos ON product_review_videos.deleted_at IS NULL"+
		" AND product_review_videos.approval_status = 'approved' AND product_review_videos.product_review_id = product_reviews.id"+
		" WHERE product_reviews.link_id = ? AND product_reviews.deleted_at IS NULL"+
		" AND (product_reviews.has_message = true OR product_review_videos.id IS NOT NULL)"+
		" ORDER BY product_reviews.rating DESC, product_reviews.created_at DESC, product_reviews.id DESC LIMIT ?",
		prod.id, publicReviewLimit)
	switch {
	case err != nil:
		return nil, err
	case video:
		// video_props reads the approved video's file, and a second one repeats the review.
		return nil, fallback("review video")
	case len(reviews) == 0:
		return []any{}, nil
	}
	byID, byPurchase := map[int64]*review{}, map[int64]*review{}
	ids, purchaseIDs := make([]int64, len(reviews)), make([]int64, len(reviews))
	for i, r := range reviews {
		if !r.createdAt.Valid || !r.purchaseID.Valid {
			// iso8601 and purchase.purchaser raise on nil.
			return nil, fallback("review row")
		}
		byID[r.id], byPurchase[r.purchaseID.Int64] = r, r
		ids[i], purchaseIDs[i] = r.id, r.purchaseID.Int64
	}
	if err := scanNamed(ctx, h.c.DB, func(cols map[string]any) func() {
		vp := &visitorPurchase{}
		cols["id"], cols["flags"], cols["purchaser_id"], cols["street_address"] = &vp.id, &vp.flags, &vp.purchaserID, &vp.streetAddress
		return func() { byPurchase[vp.id].purchase = vp }
	}, "SELECT purchases.id, purchases.flags, purchases.purchaser_id, purchases.street_address FROM purchases"+
		" WHERE purchases.id IN ("+placeholders(len(purchaseIDs))+")", int64Args(purchaseIDs)...); err != nil {
		return nil, err
	}
	if err := scanNamed(ctx, h.c.DB, func(cols map[string]any) func() {
		var id int64
		var n int
		var message sql.NullString
		cols["product_review_id"], cols["n"], cols["message"] = &id, &n, &message
		return func() { byID[id].responses, byID[id].response = n, message }
	}, "SELECT product_review_responses.product_review_id, COUNT(*) AS n, MAX(product_review_responses.message) AS message"+
		" FROM product_review_responses WHERE product_review_responses.product_review_id IN ("+placeholders(len(ids))+")"+
		" GROUP BY product_review_responses.product_review_id", int64Args(ids)...); err != nil {
		return nil, err
	}
	out := make([]any, len(reviews))
	for i, r := range reviews {
		var response any
		switch {
		case r.purchase == nil:
			return nil, fallback("review purchase")
		case r.responses > 1:
			// The has_one preload keeps whichever row MySQL returns first.
			return nil, fallback("review responses")
		case r.responses == 1:
			response = rails.NewRHash().Sym("message", nullString(r.response))
		}
		accountName, err := h.raterAccountName(p, r.purchase)
		if err != nil {
			return nil, err
		}
		// shows_account_identity?, else image_url's default avatar.
		avatar, name := h.c.Page.Avatars.AssetHost+"/images/gumroad-default-avatar-5.png", any("Anonymous")
		if !r.anonymous.Bool && rails.Present(accountName) {
			if avatar, err = h.avatarURL(ctx, r.purchase.purchaserID.Int64); err != nil {
				return nil, err
			}
			name = accountName
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
