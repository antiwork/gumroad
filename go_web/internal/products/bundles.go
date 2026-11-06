package products

import (
	"context"
	"database/sql"

	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// bundleItem is an alive bundle_products row, with the product and variant it names.
type bundleItem struct {
	productID, quantity int64
	position, variantID sql.NullInt64
	prod                *bundled
	// variant is the BaseVariant variantID names, alive or not; nil without one, or when the row
	// is gone, as belongs_to reads it.
	variant *bundleVariant
}

// bundled is a bundle product's links row and its sales_count_for_inventory_cache.
type bundled struct {
	*product
	sold sql.NullInt64
}

type bundleVariant struct {
	name                   sql.NullString
	priceDifference        sql.NullInt64
	maxPurchaseCount, sold sql.NullInt64
}

// bundle is what the page reads of its bundle_products.
type bundle struct {
	props []any
	// quantityLeft is remaining_for_sale_count's minimum over the bundle products, for a bundle.
	quantityLeft *int64
}

// loadBundle is the bundle_products prop: bundle_product_props for each alive row, in_order.
func (h *handler) loadBundle(ctx context.Context, p *page, prod *product) (*bundle, error) {
	b := &bundle{props: []any{}}
	if !p.hasBundleProducts {
		return b, nil
	}
	items, err := h.bundleItems(ctx, prod)
	if err != nil || len(items) == 0 {
		return b, err
	}
	ids, reviewed := make([]int64, len(items)), []int64{}
	for i, it := range items {
		ids[i] = it.productID
		if !prod.is(productHideBundleReviews) && it.prod.is(productDisplayReviews) {
			reviewed = append(reviewed, it.productID)
		}
	}
	prices, err := h.alivePrices(ctx, ids)
	if err != nil {
		return nil, err
	}
	stats := map[int64]*reviewStat{}
	if len(reviewed) > 0 {
		if stats, err = h.reviewStats(ctx, reviewed); err != nil {
			return nil, err
		}
	}
	thumbnails, err := h.aliveThumbnails(ctx, ids)
	if err != nil {
		return nil, err
	}
	var thumbnailRows []thumbnailRow
	for _, id := range ids {
		if t := thumbnails[id]; t != nil {
			thumbnailRows = append(thumbnailRows, *t)
		}
	}
	thumbnailURLs, err := h.thumbnailURLs(ctx, thumbnailRows)
	if err != nil {
		return nil, err
	}
	query := productPageQuery(p.layout, p.recommendedBy)
	for _, it := range items {
		bp := it.prod
		last, agreed := lastPrice(pricesForCurrency(bp.product, prices[bp.id], bp.rentOnly()))
		switch {
		case !agreed:
			return nil, fallback("bundle product prices")
		case last == nil:
			// nil + the difference raises.
			return nil, fallback("bundle product price")
		}
		var diff int64
		var variantName any
		if it.variant != nil {
			diff, variantName = it.variant.priceDifference.Int64, nullString(it.variant.name)
		}
		var ratings any
		if !prod.is(productHideBundleReviews) {
			ratings = cardRatings(bp.product, stats[bp.id])
		}
		var thumbnail any
		if t := thumbnails[bp.id]; t != nil {
			thumbnail = thumbnailURLs[t.id]
		}
		url := h.productPageURL(p, bp.generalPermalink(), query)
		b.props = append(b.props, rails.NewRHash().
			Sym("id", h.c.IDs.Encrypt(bp.id)).
			Sym("name", bp.name).
			Sym("ratings", ratings).
			Sym("price", (*last+diff)*it.quantity).
			Sym("currency_code", currencyCode(bp.product)).
			Sym("thumbnail_url", thumbnail).
			Sym("native_type", bp.nativeType).
			Sym("url", url).
			Sym("quantity", it.quantity).
			Sym("variant", variantName))
	}
	if prod.is(productIsBundle) {
		b.quantityLeft, err = h.bundleQuantityLeft(ctx, items)
	}
	return b, err
}

// bundleQuantityLeft is remaining_for_sale_count's minimum over a bundle's alive products: each
// one's own count, then its variant's quantity_left.
func (h *handler) bundleQuantityLeft(ctx context.Context, items []*bundleItem) (*int64, error) {
	if len(items) == 0 {
		return nil, nil
	}
	ids := make([]int64, len(items))
	for i, it := range items {
		ids[i] = it.productID
	}
	available, err := h.bundledVariantsAvailable(ctx, ids)
	if err != nil {
		return nil, err
	}
	var left *int64
	for _, it := range items {
		switch {
		case it.prod.is(productIsBundle):
			// Its own count would take its bundle products' in turn.
			return nil, fallback("nested bundle")
		case it.prod.is(productIsTieredMembership):
			// Closed tiers count against variants_available?, which this doesn't read.
			return nil, fallback("bundled membership")
		}
		remaining := quantityLeft(it.prod.maxPurchaseCount, it.prod.sold)
		if !available[it.productID] {
			remaining = new(int64)
		}
		left = lowerOf(left, remaining)
		if it.variant != nil {
			left = lowerOf(left, quantityLeft(it.variant.maxPurchaseCount, it.variant.sold))
		}
	}
	return left, nil
}

// bundleItems reads the alive rows in_order, with their variants, then their products.
func (h *handler) bundleItems(ctx context.Context, owner *product) ([]*bundleItem, error) {
	items, err := h.loadBundleItems(ctx, owner)
	if err != nil {
		return nil, err
	}
	for _, it := range items {
		if reason := unportedBundled(owner, it.prod.product); reason != "" {
			return nil, fallback(reason)
		}
	}
	return items, nil
}

// loadBundleItems is bundleItems without the props' shape checks, which remaining_for_sale_count
// doesn't need.
func (h *handler) loadBundleItems(ctx context.Context, owner *product) ([]*bundleItem, error) {
	items, err := h.bundleRows(ctx, owner)
	if err != nil || len(items) == 0 {
		return nil, err
	}
	ids := make([]int64, len(items))
	for i, it := range items {
		ids[i] = it.productID
	}
	products, err := h.bundledProducts(ctx, ids)
	if err != nil {
		return nil, err
	}
	for _, it := range items {
		if it.prod = products[it.productID]; it.prod == nil {
			// bundle_product.product is nil, and Rails raises.
			return nil, fallback("bundle product missing")
		}
	}
	return items, nil
}

// bundleRowsStatement is product_props' bundle_products statement as Rails writes it. in_order
// sets no tiebreak, so running the same statement leaves MySQL to order ties as it does for Rails.
const bundleRowsStatement = "SELECT `bundle_products`.* FROM `bundle_products` WHERE `bundle_products`.`bundle_id` = ?" +
	" AND `bundle_products`.`deleted_at` IS NULL ORDER BY `bundle_products`.`position` ASC"

func (h *handler) bundleRows(ctx context.Context, owner *product) ([]*bundleItem, error) {
	var items []*bundleItem
	err := scanNamed(ctx, h.c.DB, func(cols map[string]any) func() {
		it := &bundleItem{}
		cols["product_id"], cols["quantity"], cols["position"], cols["variant_id"] = &it.productID, &it.quantity, &it.position, &it.variantID
		return func() { items = append(items, it) }
	}, bundleRowsStatement, owner.id)
	if err != nil {
		return nil, err
	}
	var ids []int64
	for _, it := range items {
		if it.variantID.Valid {
			ids = append(ids, it.variantID.Int64)
		}
	}
	variants, err := h.bundleVariants(ctx, ids)
	if err != nil {
		return nil, err
	}
	for _, it := range items {
		if it.variantID.Valid {
			it.variant = variants[it.variantID.Int64]
		}
	}
	return items, nil
}

// bundleVariants is the :variant preload: the BaseVariants by id, alive or not.
func (h *handler) bundleVariants(ctx context.Context, ids []int64) (map[int64]*bundleVariant, error) {
	if len(ids) == 0 {
		return nil, nil
	}
	rows, err := h.c.DB.QueryContext(ctx, "SELECT id, type, name, price_difference_cents, max_purchase_count, sales_count_for_inventory_cache"+
		" FROM base_variants WHERE id IN ("+placeholders(len(ids))+")", int64Args(ids)...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[int64]*bundleVariant{}
	for rows.Next() {
		var id int64
		var kind sql.NullString
		v := &bundleVariant{}
		if err := rows.Scan(&id, &kind, &v.name, &v.priceDifference, &v.maxPurchaseCount, &v.sold); err != nil {
			return nil, err
		}
		if kind.String != "Variant" && kind.String != "Sku" {
			return nil, fallback("bundle product variant type")
		}
		out[id] = v
	}
	return out, rows.Err()
}

func (h *handler) bundledProducts(ctx context.Context, ids []int64) (map[int64]*bundled, error) {
	rows, err := h.c.DB.QueryContext(ctx, "SELECT "+productColumns+", links.sales_count_for_inventory_cache FROM links"+
		" WHERE links.id IN ("+placeholders(len(ids))+")", int64Args(ids)...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[int64]*bundled{}
	for rows.Next() {
		bp := &bundled{product: &product{}}
		if err := rows.Scan(append(bp.dest(), &bp.sold)...); err != nil {
			return nil, err
		}
		out[bp.id] = bp
	}
	return out, rows.Err()
}

// unportedBundled is a bundle product whose props this port doesn't follow.
func unportedBundled(owner, prod *product) string {
	switch {
	case prod.userID != owner.userID:
		// url_for_product_page would be another seller's long_url.
		return "bundle product seller"
	case prod.is(productIsBundle):
		return "nested bundle"
	case prod.is(productIsRecurringBilling) || prod.is(productIsTieredMembership):
		return "bundled membership"
	case !prod.purchaseType.Valid || prod.purchaseType.Int64 < purchaseTypeBuyOnly || prod.purchaseType.Int64 > purchaseTypeBuyAndRent:
		return "bundle product purchase type"
	case rails.Blank(prod.generalPermalink()):
		return "bundle product permalink"
	}
	return ""
}

// bundledVariantsAvailable is variants_available? for each bundle product, falling back on a
// Tier category, whose lone tier remaining_for_sale_count would read.
func (h *handler) bundledVariantsAvailable(ctx context.Context, ids []int64) (map[int64]bool, error) {
	rows, err := h.c.DB.QueryContext(ctx, "SELECT variant_categories.link_id, variant_categories.id, variant_categories.title = 'Tier',"+
		" base_variants.id, base_variants.max_purchase_count, base_variants.sales_count_for_inventory_cache FROM variant_categories"+
		" LEFT JOIN base_variants ON base_variants.variant_category_id = variant_categories.id AND base_variants.type = 'Variant'"+
		" AND base_variants.deleted_at IS NULL"+
		" WHERE variant_categories.deleted_at IS NULL AND variant_categories.link_id IN ("+placeholders(len(ids))+")", int64Args(ids)...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	byProduct := map[int64]*variants{}
	for rows.Next() {
		var productID int64
		var tier sql.NullBool
		var variantID sql.NullInt64
		o := &variantOption{}
		if err := rows.Scan(&productID, &o.categoryID, &tier, &variantID, &o.maxPurchaseCount, &o.sold); err != nil {
			return nil, err
		}
		if tier.Bool {
			return nil, fallback("bundle product tiers")
		}
		vs := byProduct[productID]
		if vs == nil {
			vs = &variants{}
			byProduct[productID] = vs
		}
		vs.categories = append(vs.categories, o.categoryID)
		if variantID.Valid {
			vs.all = append(vs.all, o)
		}
	}
	out := map[int64]bool{}
	for _, id := range ids {
		out[id] = byProduct[id] == nil || byProduct[id].available()
	}
	return out, rows.Err()
}

// quantityLeft is [max_purchase_count - sold, 0].max, or nil without a maximum.
func quantityLeft(maxPurchases, sold sql.NullInt64) *int64 {
	if !maxPurchases.Valid {
		return nil
	}
	n := max(maxPurchases.Int64-sold.Int64, 0)
	return &n
}
