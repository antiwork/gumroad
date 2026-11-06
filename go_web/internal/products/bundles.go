package products

import (
	"context"
	"database/sql"
	"slices"

	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/web"
)

// bundleItem is an alive bundle_products row, with the product and variant it names.
type bundleItem struct {
	productID, quantity int64
	variantID, position sql.NullInt64
	prod                *product
	// sold is the product's sales_count_for_inventory_cache.
	sold    sql.NullInt64
	variant *bundleVariant
}

// bundleVariant is the BaseVariant a bundle product names, alive or not.
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
	if err != nil {
		return nil, err
	}
	ids := make([]int64, len(items))
	for i, it := range items {
		ids[i] = it.productID
	}
	prices, err := h.alivePrices(ctx, ids)
	if err != nil {
		return nil, err
	}
	stats, err := h.reviewStats(ctx, ids)
	if err != nil {
		return nil, err
	}
	thumbnails, err := h.aliveThumbnails(ctx, ids)
	if err != nil {
		return nil, err
	}
	var rows []thumbnailRow
	for _, id := range ids {
		if len(thumbnails[id]) > 1 {
			// has_one's preload keeps whichever row MySQL returns first.
			return nil, fallback("bundle product thumbnails")
		}
		rows = append(rows, thumbnails[id]...)
	}
	thumbnailURLs, err := h.thumbnailURLs(ctx, rows)
	if err != nil {
		return nil, err
	}
	var available map[int64]bool
	if prod.is(productIsBundle) {
		if available, err = h.bundledVariantsAvailable(ctx, ids); err != nil {
			return nil, err
		}
	}
	for _, it := range items {
		bp := it.prod
		price, err := bundledPriceCents(bp, prices[bp.id])
		if err != nil {
			return nil, err
		}
		var diff int64
		var variantName any
		if it.variant != nil {
			diff, variantName = it.variant.priceDifference.Int64, nullString(it.variant.name)
		}
		var ratings any
		if !prod.is(productHideBundleReviews) && bp.is(productDisplayReviews) {
			stat := stats[bp.id].orTemplate()
			ratings = rails.NewRHash().Sym("count", stat.reviewsCount).Sym("average", stat.averageRating)
		}
		var thumbnail any
		if t := thumbnails[bp.id]; len(t) == 1 {
			thumbnail = thumbnailURLs[t[0].id]
		}
		// url_for_product_page on the seller's own subdomain: short_link_url on this host.
		url := web.Protocol(p.Req.HTTP) + p.Req.Host + "/l/" + web.EscapeSegment(bp.generalPermalink())
		b.props = append(b.props, rails.NewRHash().
			Sym("id", h.c.IDs.Encrypt(bp.id)).
			Sym("name", bp.name).
			Sym("ratings", ratings).
			Sym("price", (price+diff)*it.quantity).
			Sym("currency_code", currencyCode(bp)).
			Sym("thumbnail_url", thumbnail).
			Sym("native_type", bp.nativeType).
			Sym("url", url).
			Sym("quantity", it.quantity).
			Sym("variant", variantName))
		if available != nil {
			b.quantityLeft = minCents(b.quantityLeft, bundledRemaining(it, available[bp.id]))
			if it.variant != nil {
				b.quantityLeft = minCents(b.quantityLeft, quantityLeft(it.variant.maxPurchaseCount, it.variant.sold))
			}
		}
	}
	return b, nil
}

// bundleItems reads the alive rows in_order, with their products and variants.
func (h *handler) bundleItems(ctx context.Context, prod *product) ([]*bundleItem, error) {
	rows, err := h.c.DB.QueryContext(ctx, "SELECT bundle_products.product_id, bundle_products.variant_id, bundle_products.quantity,"+
		" bundle_products.position FROM bundle_products WHERE bundle_products.bundle_id = ? AND bundle_products.deleted_at IS NULL"+
		" ORDER BY bundle_products.position ASC", prod.id)
	if err != nil {
		return nil, err
	}
	var items []*bundleItem
	for rows.Next() {
		it := &bundleItem{}
		if err := rows.Scan(&it.productID, &it.variantID, &it.quantity, &it.position); err != nil {
			rows.Close()
			return nil, err
		}
		if n := len(items); n > 0 && items[n-1].position == it.position {
			rows.Close()
			// in_order leaves ties to MySQL.
			return nil, fallback("bundle product order")
		}
		items = append(items, it)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}

	ids, variantIDs := make([]int64, 0, len(items)), []int64{}
	for _, it := range items {
		ids = append(ids, it.productID)
		if it.variantID.Valid {
			variantIDs = append(variantIDs, it.variantID.Int64)
		}
	}
	products := map[int64]*bundleItem{}
	rows, err = h.c.DB.QueryContext(ctx, "SELECT "+productColumns+", links.sales_count_for_inventory_cache FROM links"+
		" WHERE links.id IN ("+placeholders(len(ids))+")", int64Args(ids)...)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		it := &bundleItem{prod: &product{}}
		if err := rows.Scan(append(it.prod.dest(), &it.sold)...); err != nil {
			rows.Close()
			return nil, err
		}
		products[it.prod.id] = it
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	variants, err := h.bundleVariants(ctx, variantIDs)
	if err != nil {
		return nil, err
	}
	for _, it := range items {
		found := products[it.productID]
		if found == nil {
			// bundle_product.product is nil, and Rails raises.
			return nil, fallback("bundle product missing")
		}
		it.prod, it.sold = found.prod, found.sold
		if reason := unportedBundled(prod, it.prod); reason != "" {
			return nil, fallback(reason)
		}
		if it.variantID.Valid {
			it.variant = variants[it.variantID.Int64]
		}
	}
	return items, nil
}

// unportedBundled is a bundle product whose props this port doesn't follow.
func unportedBundled(bundle, prod *product) string {
	switch {
	case prod.userID != bundle.userID:
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

func (h *handler) bundleVariants(ctx context.Context, ids []int64) (map[int64]*bundleVariant, error) {
	out := map[int64]*bundleVariant{}
	if len(ids) == 0 {
		return out, nil
	}
	rows, err := h.c.DB.QueryContext(ctx, "SELECT base_variants.id, base_variants.type, base_variants.name, base_variants.price_difference_cents,"+
		" base_variants.max_purchase_count, base_variants.sales_count_for_inventory_cache FROM base_variants"+
		" WHERE base_variants.id IN ("+placeholders(len(ids))+")", int64Args(ids)...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
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

// bundledPriceCents is a bundle product's Link#price_cents, from its preloaded alive_prices.
func bundledPriceCents(prod *product, rows []priceRow) (int64, error) {
	rental := prod.rentOnly()
	var kind []int64
	for _, r := range rows {
		if r.isRental() == rental && r.currency.Valid == prod.priceCurrencyType.Valid && r.currency.String == prod.priceCurrencyType.String {
			kind = append(kind, r.cents)
		}
	}
	switch {
	case len(kind) == 0:
		// nil + the difference raises.
		return 0, fallback("bundle product price")
	case slices.Min(kind) != slices.Max(kind):
		// Which one is last is the preload's row order.
		return 0, fallback("bundle product prices")
	}
	return kind[len(kind)-1], nil
}

// bundledVariantsAvailable is variants_available? for each bundle product, and whether it
// has a Tier category, whose lone tier remaining_for_sale_count would read.
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
	// A category is available with no alive variants or one in stock; a product, with no
	// category or one available.
	categoryOK := map[int64]bool{}
	categoryOf := map[int64]int64{}
	for rows.Next() {
		var productID, categoryID int64
		var tier sql.NullBool
		var variantID, maxPurchases, sold sql.NullInt64
		if err := rows.Scan(&productID, &categoryID, &tier, &variantID, &maxPurchases, &sold); err != nil {
			return nil, err
		}
		if tier.Bool {
			return nil, fallback("bundle product tiers")
		}
		categoryOf[categoryID] = productID
		if q := quantityLeft(maxPurchases, sold); !variantID.Valid || q == nil || *q > 0 {
			categoryOK[categoryID] = true
		} else if _, seen := categoryOK[categoryID]; !seen {
			categoryOK[categoryID] = false
		}
	}
	out := map[int64]bool{}
	for _, id := range ids {
		out[id] = true
	}
	hasCategory := map[int64]bool{}
	for category, productID := range categoryOf {
		if !hasCategory[productID] {
			hasCategory[productID], out[productID] = true, false
		}
		if categoryOK[category] {
			out[productID] = true
		}
	}
	return out, rows.Err()
}

// bundledRemaining is a bundle product's remaining_for_sale_count, which has no tiers here.
func bundledRemaining(it *bundleItem, variantsAvailable bool) *int64 {
	if !variantsAvailable {
		zero := int64(0)
		return &zero
	}
	return quantityLeft(it.prod.maxPurchaseCount, it.sold)
}

// quantityLeft is [max_purchase_count - sold, 0].max, or nil without a maximum.
func quantityLeft(maxPurchases, sold sql.NullInt64) *int64 {
	if !maxPurchases.Valid {
		return nil
	}
	n := max(maxPurchases.Int64-sold.Int64, 0)
	return &n
}
