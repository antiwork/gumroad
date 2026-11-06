package products

import (
	"context"
	"database/sql"
	"encoding/json"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/web"
)

const (
	productComponent    = "Products/Show"
	storefrontComponent = "Products/Profile/Show"
	// ProfileSectionsPresenter::DEFAULT_PRODUCTS_SECTION_ID and _TYPE, and ProductSortKey::PAGE_LAYOUT.
	defaultProductsSectionID   = "default-products"
	profileProductsSectionType = "SellerProfileProductsSection"
	pageLayoutSort             = "page_layout"
	catalogPageSize            = 9
	// cached_default_products_section's expires_in.
	catalogTTL = 10 * time.Minute
)

// catalogSearch is section_search_results(nil): the seller's products on their profile,
// newest first, with SearchProducts' tag and filetype facets.
type catalogSearch struct {
	Total     int64           `json:"total"`
	Tags      []catalogBucket `json:"tags"`
	Filetypes []catalogBucket `json:"filetypes"`
	IDs       []int64         `json:"ids"`
}

type catalogBucket struct {
	Key      string `json:"key"`
	DocCount int64  `json:"doc_count"`
}

func bucketsProps(buckets []catalogBucket) []any {
	out := make([]any, 0, len(buckets))
	for _, b := range buckets {
		out = append(out, rails.NewRHash().Str("key", b.Key).Str("doc_count", b.DocCount))
	}
	return out
}

// storefront is show_storefront_catalog? for a signed-out visitor, whose page has no
// sections of its own (unportedShape) and isn't the Discover layout (a declined param).
func storefront(p *page) bool { return p.seller.is(userProductPageStorefrontEnabled) }

// loadCatalog is ProductPresenter#product_page_props' storefront sections:
// ProfileSectionsPresenter#props over the seller's profile products sections, with the virtual
// default-products section and omit_product.
func (h *handler) loadCatalog(p *page, prod *product, buyer *string) ([]any, error) {
	ctx, seller := p.Ctx, p.seller
	saved, err := h.exists(ctx, "SELECT 1 FROM seller_profile_sections WHERE seller_profile_sections.seller_id = ?"+
		" AND seller_profile_sections.type = ? AND seller_profile_sections.product_id IS NULL LIMIT 1", seller.id, profileProductsSectionType)
	if err != nil || saved {
		return nil, firstErr(err, fallback("storefront sections"))
	}
	// default_products_section_available?
	listed, err := h.exists(ctx, "SELECT 1 FROM links WHERE links.user_id = ? AND links.purchase_disabled_at IS NULL"+
		" AND links.banned_at IS NULL AND links.deleted_at IS NULL AND (links.flags & ?) = 0 LIMIT 1", seller.id, productArchived)
	if err != nil || !listed {
		return []any{}, err
	}
	s, err := h.cachedCatalog(p)
	if err != nil {
		return nil, err
	}
	cards, err := h.loadCards(p, s.IDs)
	if err != nil {
		return nil, err
	}
	total := s.Total
	kept := make([]*card, 0, len(cards))
	for _, c := range cards {
		if c.prod.id != prod.id {
			kept = append(kept, c)
		}
	}
	// omit_product: one fewer whether it was on the page or only counted beyond it.
	if len(kept) < len(cards) || prod.alive() && !prod.is(productArchived) && prod.userID == seller.id {
		total--
	}
	shown := make([]*card, 0, len(kept))
	for _, c := range kept {
		if c.prod.is(productHideSoldOutVariants) {
			soldOut, err := h.cardSoldOut(p, c)
			if err != nil {
				return nil, err
			}
			if soldOut {
				total--
				continue
			}
		}
		shown = append(shown, c)
	}
	if err := h.cardThumbnails(p, shown); err != nil {
		return nil, err
	}
	products := make([]any, 0, len(shown))
	for _, c := range shown {
		props, err := h.cardProps(p, c, buyer)
		if err != nil {
			return nil, err
		}
		products = append(products, props)
	}
	results := rails.NewRHash().
		Sym("total", total).
		Sym("tags_data", bucketsProps(s.Tags)).
		Sym("filetypes_data", bucketsProps(s.Filetypes)).
		Sym("taxonomy_attributes_data", []any{}).
		Sym("products", products)
	return []any{rails.NewRHash().
		Sym("id", defaultProductsSectionID).
		Sym("header", "More from "+nameOrUsername(seller)).
		Sym("type", profileProductsSectionType).
		Sym("show_filters", false).
		Sym("default_product_sort", pageLayoutSort).
		Sym("search_results", results).
		Sym("exclude_ids", []any{h.c.IDs.Encrypt(prod.id)})}, nil
}

// cachedCatalog is cached_default_products_section's search, under a key of go_web's own that
// moves with the seller's products as Rails' does. Rails never reads it, so it's written even
// when the page then goes to Rails.
func (h *handler) cachedCatalog(p *page) (*catalogSearch, error) {
	productsKey, err := h.productsCacheKey(p)
	if err != nil {
		return nil, err
	}
	key := "go-web:storefront-catalog_" + productsKey
	cached, found, err := h.readCache(p.Ctx, key)
	if err != nil {
		return nil, err
	}
	if found {
		var s catalogSearch
		if text, ok := cached.(string); !ok || json.Unmarshal([]byte(text), &s) != nil {
			return nil, fallback("cached catalog")
		}
		return &s, nil
	}
	s, err := h.searchCatalog(p)
	if err != nil {
		return nil, err
	}
	text, err := json.Marshal(s)
	if err != nil {
		return nil, err
	}
	if !p.DryRun {
		if err := h.c.Page.Cache.Write(context.WithoutCancel(p.Ctx), key, string(text), catalogTTL); err != nil {
			web.Logger(p.Req.HTTP).Warn("catalog cache write failed", "error", err.Error())
		}
	}
	return s, nil
}

// searchCatalog is Link.filetype_options' and Link.search_options' searches for the virtual
// section. They share a query, so one request carries both facets.
func (h *handler) searchCatalog(p *page) (*catalogSearch, error) {
	terms := func(field string, size int) map[string]any {
		return map[string]any{"terms": map[string]any{"field": field, "size": size}}
	}
	var products struct {
		Hits struct {
			Total struct {
				Value    int64  `json:"value"`
				Relation string `json:"relation"`
			} `json:"total"`
			Hits []struct {
				ID   string            `json:"_id"`
				Sort []json.RawMessage `json:"sort"`
			} `json:"hits"`
		} `json:"hits"`
		Aggregations struct {
			Tags struct {
				Buckets []catalogBucket `json:"buckets"`
			} `json:"tags.keyword"`
			Filetypes struct {
				Buckets []catalogBucket `json:"buckets"`
			} `json:"filetypes.keyword"`
		} `json:"aggregations"`
	}
	err := h.c.Page.Search.Search(p.Ctx, "products", map[string]any{
		"query": map[string]any{"bool": map[string]any{"must": []any{
			map[string]any{"terms": map[string]any{"user_id": []int64{p.seller.id}}},
			map[string]any{"term": map[string]any{"is_alive_on_profile": true}},
		}}},
		"aggregations": map[string]any{"tags.keyword": terms("tags.keyword", 200), "filetypes.keyword": terms("filetypes.keyword", 8)},
		// One hit past the page shows whether its last one ties with the next.
		"sort": []any{map[string]any{"created_at": map[string]any{"order": "desc"}}}, "size": catalogPageSize + 1, "from": 0,
		"_source": false, "track_total_hits": true}, &products)
	if err != nil {
		return nil, searchFailed(p, "catalog", err)
	}
	if products.Hits.Total.Relation != "eq" {
		return nil, fallback("catalog total")
	}
	s := &catalogSearch{Total: products.Hits.Total.Value, Tags: products.Aggregations.Tags.Buckets,
		Filetypes: products.Aggregations.Filetypes.Buckets, IDs: []int64{}}
	var last string
	for _, hit := range products.Hits.Hits {
		id, err := strconv.ParseInt(hit.ID, 10, 64)
		if err != nil || len(hit.Sort) != 1 {
			return nil, fallback("catalog hit")
		}
		if sort := string(hit.Sort[0]); sort == last {
			// Hits tied on created_at come back in whichever order a shard copy keeps them.
			return nil, fallback("catalog order")
		} else {
			last = sort
		}
		s.IDs = append(s.IDs, id)
	}
	if len(s.IDs) > catalogPageSize {
		s.IDs = s.IDs[:catalogPageSize]
	}
	return s, nil
}

// card is a catalog product as ProductPresenter::Card reads it.
type card struct {
	prod *product
	// defaultRecurrence is subscription_duration.to_s.
	defaultRecurrence    string
	prices               []priceRow
	minVariantDifference sql.NullInt64
	stat                 *reviewStat
	thumbnails           []thumbnailRow
	hasTier, hasPlan     bool
	thumbnailURL         any
}

// subscriptionDurations is Link's subscription_duration enum, in its integer order.
var subscriptionDurations = []string{"monthly", "yearly", "quarterly", "biannually", "every_two_years"}

// loadCards is section_props' Link.find of the hits, in hit order, for the shapes whose card
// this port renders.
func (h *handler) loadCards(p *page, ids []int64) ([]*card, error) {
	if len(ids) == 0 {
		return nil, nil
	}
	ctx := p.Ctx
	byID := make(map[int64]*card, len(ids))
	rows, err := h.c.DB.QueryContext(ctx, "SELECT "+productColumns+", links.subscription_duration,"+
		" EXISTS(SELECT 1 FROM base_variants WHERE base_variants.link_id = links.id AND base_variants.type = 'Sku' AND base_variants.deleted_at IS NULL),"+
		" EXISTS(SELECT 1 FROM variant_categories WHERE variant_categories.link_id = links.id AND variant_categories.deleted_at IS NULL"+
		" AND variant_categories.title = 'Tier'),"+
		" EXISTS(SELECT 1 FROM product_installment_plans WHERE product_installment_plans.link_id = links.id"+
		" AND product_installment_plans.deleted_at IS NULL)"+
		" FROM links WHERE links.id IN ("+placeholders(len(ids))+")", int64Args(ids)...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		c := &card{prod: &product{}}
		var duration sql.NullInt64
		var hasSku bool
		if err := rows.Scan(append(c.prod.dest(), &duration, &hasSku, &c.hasTier, &c.hasPlan)...); err != nil {
			return nil, err
		}
		if reason := unportedCard(p.seller.id, c.prod, hasSku); reason != "" {
			return nil, fallback("catalog " + reason)
		}
		if duration.Valid {
			if duration.Int64 < 0 || duration.Int64 >= int64(len(subscriptionDurations)) {
				return nil, fallback("catalog subscription duration")
			}
			c.defaultRecurrence = subscriptionDurations[duration.Int64]
		}
		byID[c.prod.id] = c
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	rows.Close()
	cards := make([]*card, len(ids))
	for i, id := range ids {
		if cards[i] = byID[id]; cards[i] == nil {
			// Link.find raises.
			return nil, fallback("catalog product missing")
		}
	}
	prices, err := h.alivePrices(ctx, ids)
	if err != nil {
		return nil, err
	}
	stats, err := h.reviewStats(ctx, ids)
	if err != nil {
		return nil, err
	}
	floors, err := h.variantPriceFloors(ctx, ids)
	if err != nil {
		return nil, err
	}
	thumbnails, err := h.aliveThumbnails(ctx, ids)
	if err != nil {
		return nil, err
	}
	for id, c := range byID {
		c.prices, c.stat, c.minVariantDifference, c.thumbnails = prices[id], stats[id], floors[id], thumbnails[id]
	}
	return cards, nil
}

// variantPriceFloors is lowest_variant_price_difference_cents over each product's preloaded
// alive variants.
func (h *handler) variantPriceFloors(ctx context.Context, ids []int64) (map[int64]sql.NullInt64, error) {
	rows, err := h.c.DB.QueryContext(ctx, "SELECT variant_categories.link_id, MIN(base_variants.price_difference_cents) FROM base_variants"+
		" INNER JOIN variant_categories ON variant_categories.id = base_variants.variant_category_id"+
		" WHERE base_variants.type = 'Variant' AND base_variants.deleted_at IS NULL AND variant_categories.deleted_at IS NULL"+
		" AND variant_categories.link_id IN ("+placeholders(len(ids))+") GROUP BY variant_categories.link_id", int64Args(ids)...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[int64]sql.NullInt64{}
	for rows.Next() {
		var id int64
		var floor sql.NullInt64
		if err := rows.Scan(&id, &floor); err != nil {
			return nil, err
		}
		out[id] = floor
	}
	return out, rows.Err()
}

// aliveThumbnails is each product's thumbnail_alive rows.
func (h *handler) aliveThumbnails(ctx context.Context, ids []int64) (map[int64][]thumbnailRow, error) {
	rows, err := h.c.DB.QueryContext(ctx, "SELECT thumbnails.product_id, thumbnails.id, thumbnails.unsplash_url FROM thumbnails"+
		" WHERE thumbnails.deleted_at IS NULL AND thumbnails.product_id IN ("+placeholders(len(ids))+")", int64Args(ids)...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[int64][]thumbnailRow{}
	for rows.Next() {
		var id int64
		var t thumbnailRow
		if err := rows.Scan(&id, &t.id, &t.unsplash); err != nil {
			return nil, err
		}
		out[id] = append(out[id], t)
	}
	return out, rows.Err()
}

// unportedCard is a catalog product whose card this port leaves to Rails.
func unportedCard(sellerID int64, prod *product, hasSku bool) string {
	_, known := currencies[prod.productCurrency()]
	switch {
	case prod.userID != sellerID:
		// url_for_product_page and the seller's auto-apply code are the subdomain seller's.
		return "seller"
	case !prod.purchaseType.Valid || prod.purchaseType.Int64 != purchaseTypeBuyOnly:
		return "rental"
	case prod.is(productIsRecurringBilling) || prod.is(productIsTieredMembership):
		return "membership"
	case prod.defaultOfferCodeID.Valid:
		return "default offer code"
	case hasSku:
		return "skus"
	case !prod.priceCurrencyType.Valid || !known:
		return "currency"
	}
	return ""
}

// cardSoldOut is hide_sold_out_variants? && remaining_for_sale_count == 0.
func (h *handler) cardSoldOut(p *page, c *card) (bool, error) {
	if c.hasTier || c.prod.is(productIsBundle) {
		return false, fallback("catalog inventory")
	}
	vs, err := h.loadVariants(p.Ctx, c.prod)
	if err != nil {
		return false, err
	}
	remaining, err := h.remainingForSaleCount(p.Ctx, c.prod, vs)
	return remaining == int64(0), err
}

// cardProps is ProductPresenter::Card#for_web for section_props: no seller, inventory or
// description, and a product URL on this subdomain with layout=profile.
func (h *handler) cardProps(p *page, c *card, buyer *string) (*rails.RHash, error) {
	prod := c.prod
	buy := buyPrices(prod, c.prices)
	if len(buy) > 1 && slices.Min(buy) != slices.Max(buy) {
		// Which one is last is the preload's row order.
		return nil, fallback("catalog price")
	}
	var price int64
	if len(buy) > 0 {
		price = buy[len(buy)-1]
	}
	price += c.minVariantDifference.Int64
	// default_price_recurrence: every match has the recurrence it matched on.
	var recurrence any
	for _, r := range c.prices {
		if r.recurrence.Valid && r.recurrence.String == c.defaultRecurrence {
			recurrence = r.recurrence.String
			break
		}
	}
	var ratings any
	if prod.is(productDisplayReviews) {
		stat := c.stat.orTemplate()
		ratings = rails.NewRHash().Sym("count", stat.reviewsCount).Sym("average", stat.averageRating)
	}
	pc := prod.productCurrency()
	var display *currencyDisplay
	if buyer != nil {
		if *buyer != pc && *buyer != "usd" && (prod.is(productFreeTrialEnabled) || prod.is(productIsInPreorderState) ||
			prod.nativeType == "commission" || c.hasPlan) {
			// buyer_currency_unquotable_product? may turn the local price off.
			return nil, fallback("catalog unquotable product")
		}
		var err error
		if display, err = h.currencyDisplayFor(p, *buyer, pc, &price); err != nil {
			return nil, err
		}
	}
	externalID := h.c.IDs.Encrypt(prod.id)
	props := rails.NewRHash().
		Sym("id", externalID).
		Sym("permalink", nullString(prod.uniquePermalink)).
		Sym("name", prod.name).
		Sym("seller", nil).
		Sym("ratings", ratings).
		Sym("thumbnail_url", c.thumbnailURL).
		Sym("native_type", prod.nativeType).
		Sym("quantity_remaining", nil).
		Sym("is_sales_limited", false).
		Sym("price_cents", price).
		Sym("currency_code", pc).
		Sym("buyer_currency_display", buyerCurrencyDisplay(externalID, pc, display))
	buyerLocalPriceProps(props, pc, display)
	// url_for_product_page on the seller's own subdomain, whose port declined() rules out.
	url := web.Protocol(p.Req.HTTP) + p.Req.Host + "/l/" + web.EscapeSegment(prod.generalPermalink()) + "?layout=profile"
	return props.
		Sym("is_pay_what_you_want", prod.customizablePrice.Bool).
		Sym("url", url).
		Sym("duration_in_months", nullInt(prod.durationInMonths)).
		Sym("recurrence", recurrence), nil
}

// cardThumbnails is thumbnail_or_cover_url for each card: thumbnail_alive&.url, else the
// first image cover's url.
func (h *handler) cardThumbnails(p *page, cards []*card) error {
	var uncovered []int64
	for _, c := range cards {
		switch len(c.thumbnails) {
		case 0:
		case 1:
			url, err := h.thumbnailRowURL(p.Ctx, c.thumbnails[0])
			if err != nil {
				return err
			}
			if url != nil {
				c.thumbnailURL = url
				continue
			}
		default:
			// has_one's preload keeps whichever row MySQL returns first.
			return fallback("catalog thumbnails")
		}
		uncovered = append(uncovered, c.prod.id)
	}
	if len(uncovered) == 0 {
		return nil
	}
	urls, err := h.firstImageCoverURLs(p, uncovered)
	if err != nil {
		return err
	}
	for _, c := range cards {
		if url, ok := urls[c.prod.id]; ok {
			c.thumbnailURL = url
		}
	}
	return nil
}

// firstImageCoverURLs is display_asset_previews.find(&:image_url?)&.url for each product. Only
// that cover's URL is read, as Rails reads it.
func (h *handler) firstImageCoverURLs(p *page, ids []int64) (map[int64]string, error) {
	rows, err := h.c.DB.QueryContext(p.Ctx, `SELECT asset_previews.link_id, asset_previews.id, asset_previews.position,
		asset_previews.created_at, asset_previews.unsplash_url, asset_previews.oembed IS NOT NULL, att.id, blobs.id, blobs.key,
		blobs.filename, blobs.content_type, blobs.metadata
		FROM asset_previews
		LEFT JOIN active_storage_attachments att ON att.record_type = 'AssetPreview' AND att.record_id = asset_previews.id
			AND att.name = 'file'
		LEFT JOIN active_storage_blobs blobs ON blobs.id = att.blob_id
		WHERE asset_previews.link_id IN (`+placeholders(len(ids))+`) AND asset_previews.deleted_at IS NULL
		ORDER BY asset_previews.link_id, asset_previews.position ASC, asset_previews.created_at ASC, asset_previews.id ASC`, int64Args(ids)...)
	if err != nil {
		return nil, err
	}
	type preview struct {
		id, link             int64
		order                coverOrder
		unsplash             sql.NullString
		oembed               bool
		attID, blobID        sql.NullInt64
		key, filename, ctype sql.NullString
		metadata             sql.NullString
	}
	var previews []preview
	for rows.Next() {
		var r preview
		if err := rows.Scan(&r.link, &r.id, &r.order.position, &r.order.createdAt, &r.unsplash, &r.oembed, &r.attID, &r.blobID,
			&r.key, &r.filename, &r.ctype, &r.metadata); err != nil {
			rows.Close()
			return nil, err
		}
		if n := len(previews); n > 0 && previews[n-1].id == r.id || r.attID.Valid && !r.blobID.Valid {
			rows.Close()
			return nil, fallback("cover attachment")
		}
		previews = append(previews, r)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	imageURL := func(r preview) bool {
		return rails.Present(r.unsplash.String) || r.attID.Valid && strings.HasPrefix(r.ctype.String, "image")
	}
	urls := map[int64]string{}
	for _, r := range previews {
		if _, done := urls[r.link]; done || !imageURL(r) {
			continue
		}
		for _, o := range previews {
			if o.link == r.link && o.id != r.id && o.order == r.order && imageURL(o) {
				return nil, fallback("cover order")
			}
		}
		switch {
		case rails.Present(r.unsplash.String):
			urls[r.link] = r.unsplash.String
			continue
		case r.oembed:
			return nil, fallback("oembed cover")
		}
		c := &cover{attachmentID: r.attID.Int64, blobID: r.blobID.Int64, key: r.key.String, filename: r.filename.String,
			contentType: r.ctype.String, postProcess: !strings.Contains(r.ctype.String, "gif")}
		if c.width, c.height, err = blobDimensions(r.metadata.String); err != nil {
			return nil, fallback("cover metadata")
		}
		var url string
		if c.postProcess {
			url, err = h.retinaCoverURL(p.Ctx, p, c)
		} else {
			url, err = h.originalCoverURL(p.Ctx, p, c)
		}
		if err != nil {
			return nil, err
		}
		urls[r.link] = url
	}
	return urls, nil
}
