package products

import (
	"context"
	"database/sql"
	"slices"
	"strings"

	"github.com/antiwork/gumroad/go_web/internal/db"
	"github.com/antiwork/gumroad/go_web/internal/delivery"
	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// variantOption is an alive Variant, as BaseVariant#to_option reads it, or an alive SKU, as
// Sku#to_option_for_product does; a SKU's customizable_price is never read.
type variantOption struct {
	id, categoryID                     int64
	externalID                         string
	name, description                  sql.NullString
	maxPurchaseCount, sold             sql.NullInt64
	priceDifference, durationInMinutes sql.NullInt64
	customizablePrice                  sql.NullBool
	position                           sql.NullInt64
	createdAt                          db.NullTime
	flags                              int64
	sku                                bool
	// closed is closed_to_new_buyers?.
	closed bool
	// buyPrices are a tier's alive buy VariantPrices, in id order.
	buyPrices []variantPrice
}

// variantPrice is a VariantPrice row as recurrence_price_values reads it.
type variantPrice struct {
	cents      int64
	suggested  sql.NullInt64
	recurrence sql.NullString
}

// BaseVariant#closed_to_new_purchases.
const baseVariantClosedToNewPurchases int64 = 1 << 2

// quantityLeft is BaseVariant#quantity_left, with the counter read with the row.
func (o *variantOption) quantityLeft() *int64 { return quantityLeft(o.maxPurchaseCount, o.sold) }

// available is BaseVariant#available? for an alive Variant.
func (o *variantOption) available() bool {
	q := o.quantityLeft()
	return !o.closed && (q == nil || *q > 0)
}

// variants are the product's alive categories and Variants.
type variants struct {
	categories []int64
	// options is option_records: the alive SKUs but the default one when SKUs are enabled,
	// else the first category's Variants, in_order.
	options []*variantOption
	all     []*variantOption
	// tiers is Link#tiers: the Variants of the categories titled Tier.
	tiers []*variantOption
}

func (h *handler) loadVariants(ctx context.Context, prod *product) (*variants, error) {
	vs, err := h.loadCategoryVariants(ctx, prod)
	if err != nil {
		return nil, err
	}
	if prod.is(productIsTieredMembership) {
		return vs, h.loadTierPrices(ctx, slices.Concat(vs.options, vs.tiers))
	}
	if !prod.is(productSkusEnabled) {
		return vs, nil
	}
	// skus_alive_not_default has no order; both its index and the primary key give id order.
	rows, err := h.c.DB.QueryContext(ctx, "SELECT base_variants.id, base_variants.name, base_variants.description,"+
		" base_variants.max_purchase_count, base_variants.sales_count_for_inventory_cache, base_variants.price_difference_cents,"+
		" base_variants.duration_in_minutes FROM base_variants WHERE base_variants.type = 'Sku' AND base_variants.link_id = ?"+
		" AND base_variants.deleted_at IS NULL AND (base_variants.flags & ? = 0) ORDER BY base_variants.id", prod.id, baseVariantIsDefaultSku)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		o := &variantOption{sku: true}
		if err := rows.Scan(&o.id, &o.name, &o.description, &o.maxPurchaseCount, &o.sold, &o.priceDifference, &o.durationInMinutes); err != nil {
			return nil, err
		}
		o.externalID = h.c.IDs.Encrypt(o.id)
		vs.options = append(vs.options, o)
	}
	return vs, rows.Err()
}

// loadCategoryVariants reads every alive category and Variant. Rails takes the first category
// in MySQL's order, which for this index is id order.
func (h *handler) loadCategoryVariants(ctx context.Context, prod *product) (*variants, error) {
	vs, skus := &variants{}, prod.is(productSkusEnabled)
	// is_tier_category is where(title: "Tier"), so MySQL's collation decides it.
	rows, err := h.c.DB.QueryContext(ctx, "SELECT variant_categories.id, variant_categories.title = 'Tier' FROM variant_categories"+
		" WHERE variant_categories.deleted_at IS NULL AND variant_categories.link_id = ? ORDER BY variant_categories.id", prod.id)
	if err != nil {
		return nil, err
	}
	tierCategories := map[int64]bool{}
	for rows.Next() {
		var id int64
		var tier sql.NullBool
		if err := rows.Scan(&id, &tier); err != nil {
			rows.Close()
			return nil, err
		}
		vs.categories = append(vs.categories, id)
		tierCategories[id] = tier.Bool
	}
	rows.Close()
	if err := rows.Err(); err != nil || len(vs.categories) == 0 {
		return vs, err
	}
	rows, err = h.c.DB.QueryContext(ctx, "SELECT base_variants.id, base_variants.variant_category_id, base_variants.name,"+
		" base_variants.description, base_variants.max_purchase_count, base_variants.sales_count_for_inventory_cache,"+
		" base_variants.price_difference_cents, base_variants.duration_in_minutes, base_variants.customizable_price,"+
		" base_variants.position_in_category, base_variants.created_at, base_variants.flags FROM base_variants"+
		" INNER JOIN variant_categories ON base_variants.variant_category_id = variant_categories.id"+
		" WHERE base_variants.type = 'Variant' AND variant_categories.link_id = ? AND variant_categories.deleted_at IS NULL"+
		" AND base_variants.deleted_at IS NULL"+
		" ORDER BY base_variants.position_in_category ASC, base_variants.created_at ASC, base_variants.id ASC", prod.id)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	tied := false
	for rows.Next() {
		o := &variantOption{}
		if err := rows.Scan(&o.id, &o.categoryID, &o.name, &o.description, &o.maxPurchaseCount, &o.sold, &o.priceDifference,
			&o.durationInMinutes, &o.customizablePrice, &o.position, &o.createdAt, &o.flags); err != nil {
			return nil, err
		}
		vs.all = append(vs.all, o)
		if tierCategories[o.categoryID] {
			vs.tiers = append(vs.tiers, o)
		}
		// With SKUs enabled, Rails never orders these.
		if o.categoryID == vs.categories[0] && !skus {
			if n := len(vs.options); n > 0 && sameOrder(vs.options[n-1], o) {
				tied = true
			}
			o.externalID = h.c.IDs.Encrypt(o.id)
			vs.options = append(vs.options, o)
		}
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	rows.Close()
	if tied {
		if err := h.orderTiedOptions(ctx, prod.id, vs.categories[0], vs.options); err != nil {
			return nil, err
		}
	}
	if !prod.is(productIsTieredMembership) {
		return vs, nil
	}
	return vs, h.markClosedTiers(ctx, prod.userID, vs.all)
}

// markClosedTiers sets closed_to_new_buyers? on a tiered membership's Variants. The flag is
// read only for a Variant with the bit, as Rails does.
func (h *handler) markClosedTiers(ctx context.Context, sellerID int64, options []*variantOption) error {
	on, read := false, false
	for _, o := range options {
		if o.flags&baseVariantClosedToNewPurchases == 0 {
			continue
		}
		if !read {
			var err error
			if on, err = h.flag(ctx, "close_membership_tier_to_new_buyers", sellerID); err != nil {
				return err
			}
			read = true
		}
		o.closed = on
	}
	return nil
}

// loadTierPrices reads the alive buy VariantPrices of the options and tiers, which
// recurrence_price_values and lowest_tier_price read.
func (h *handler) loadTierPrices(ctx context.Context, all []*variantOption) error {
	if len(all) == 0 {
		return nil
	}
	byID := map[int64]*variantOption{}
	for _, o := range all {
		byID[o.id] = o
	}
	ids := variantIDs(all)
	rows, err := h.c.DB.QueryContext(ctx, "SELECT prices.variant_id, prices.price_cents, prices.suggested_price_cents, prices.recurrence"+
		" FROM prices WHERE prices.variant_id IN ("+placeholders(len(ids))+") AND prices.deleted_at IS NULL AND (prices.flags & ? = 0)"+
		" ORDER BY prices.id", append(int64Args(ids), priceIsRental)...)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var id int64
		var p variantPrice
		if err := rows.Scan(&id, &p.cents, &p.suggested, &p.recurrence); err != nil {
			return err
		}
		byID[id].buyPrices = append(byID[id].buyPrices, p)
	}
	return rows.Err()
}

// optionRecordsStatement is option_records' statement for a product's first category, as Rails
// writes it.
const optionRecordsStatement = "SELECT `base_variants`.* FROM `base_variants` INNER JOIN `variant_categories`" +
	" ON `base_variants`.`variant_category_id` = `variant_categories`.`id` WHERE `base_variants`.`type` = 'Variant'" +
	" AND `variant_categories`.`link_id` = ? AND `base_variants`.`variant_category_id` = ? AND `base_variants`.`deleted_at` IS NULL" +
	" ORDER BY `base_variants`.`position_in_category` ASC, `base_variants`.`created_at` ASC"

// orderTiedOptions puts options in the order option_records' statement returns them: in_order
// sets no tiebreak, so MySQL's plan for that same statement orders the ties.
func (h *handler) orderTiedOptions(ctx context.Context, productID, categoryID int64, options []*variantOption) error {
	byID := make(map[int64]*variantOption, len(options))
	for _, o := range options {
		byID[o.id] = o
	}
	ids, err := h.scanIDs(ctx, optionRecordsStatement, productID, categoryID)
	if err != nil {
		return err
	}
	var ordered []*variantOption
	for _, id := range ids {
		if o := byID[id]; o != nil {
			ordered = append(ordered, o)
		}
	}
	if len(ordered) != len(options) {
		// The two reads disagree on which options there are.
		return fallback("variant order")
	}
	copy(options, ordered)
	return nil
}

func sameOrder(a, b *variantOption) bool {
	return a.position == b.position && a.createdAt.Valid == b.createdAt.Valid && a.createdAt.Time.Equal(b.createdAt.Time)
}

// available is variants_available?: no category, or one with no alive Variants or one available.
func (vs *variants) available() bool {
	if len(vs.categories) == 0 {
		return true
	}
	for _, c := range vs.categories {
		alive, available := false, false
		for _, o := range vs.all {
			if o.categoryID != c {
				continue
			}
			alive = true
			if o.available() {
				available = true
			}
		}
		if !alive || available {
			return true
		}
	}
	return false
}

// toOptionName is to_option's name: the product's for an Untitled Variant, "" for none; or
// to_option_for_product's, a SKU's own.
func (o *variantOption) toOptionName(prod *product) any {
	if o.sku {
		return nullString(o.name)
	}
	if o.name.String == "Untitled" {
		return prod.name
	}
	return o.name.String
}

// optionsProps is Link#options: to_option for each Variant, or to_option_for_product for each
// SKU. tierRecurrences is what a tiered membership's tiers read; see tierRecurrences.
func (h *handler) optionsProps(prod *product, vs *variants, tierRecurrences map[string]bool) []any {
	out := make([]any, 0, len(vs.options))
	for _, o := range vs.options {
		quantityLeft := intOrNil(o.quantityLeft())
		if o.closed {
			quantityLeft = int64(0)
		}
		var recurrencePrices any
		if prod.is(productIsTieredMembership) {
			recurrencePrices = o.recurrencePriceValues(tierRecurrences)
		}
		out = append(out, rails.NewRHash().
			Sym("id", o.externalID).
			Sym("name", o.toOptionName(prod)).
			Sym("quantity_left", quantityLeft).
			Sym("description", o.description.String).
			Sym("price_difference_cents", nullInt(o.priceDifference)).
			Sym("recurrence_price_values", recurrencePrices).
			Sym("is_pwyw", o.customizablePrice.Bool).
			Sym("duration_in_minutes", nullInt(o.durationInMinutes)))
	}
	return out
}

// recurrencePriceValues is Variant#recurrence_price_values: for each recurrence the product
// sells at, the tier's first alive buy price there.
func (o *variantOption) recurrencePriceValues(tierRecurrences map[string]bool) *rails.RHash {
	out := rails.NewRHash()
	for _, r := range allRecurrences {
		if !tierRecurrences[r.name] {
			continue
		}
		for _, p := range o.buyPrices {
			if p.recurrence.Valid && p.recurrence.String == r.name {
				out.Str(r.name, rails.NewRHash().Sym("price_cents", p.cents).Sym("suggested_price_cents", nullInt(p.suggested)))
				break
			}
		}
	}
	return out
}

// richContents is each owner's alive rich_contents, for has_editor_content? and the files
// they embed.
func (h *handler) richContents(ctx context.Context, entityType string, ids []int64) (map[int64][]*delivery.RichContent, error) {
	out := map[int64][]*delivery.RichContent{}
	if len(ids) == 0 {
		return out, nil
	}
	rows, err := h.c.DB.QueryContext(ctx, "SELECT rich_contents.entity_id, rich_contents.title, rich_contents.description FROM rich_contents"+
		" WHERE rich_contents.entity_type = ? AND rich_contents.entity_id IN ("+placeholders(len(ids))+") AND rich_contents.deleted_at IS NULL",
		append([]any{entityType}, int64Args(ids)...)...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var owner int64
		c := &delivery.RichContent{}
		if err := rows.Scan(&owner, &c.Title, &c.DescriptionJSON); err != nil {
			return nil, err
		}
		out[owner] = append(out[owner], c)
	}
	return out, rows.Err()
}

func anyEditorContent(contents []*delivery.RichContent) (bool, error) {
	for _, c := range contents {
		has, err := c.HasEditorContent()
		if err != nil {
			return false, fallback("rich content")
		}
		if has {
			return true, nil
		}
	}
	return false, nil
}

// variantFiles is each Variant's product_files, alive.
func (h *handler) variantFiles(ctx context.Context, ids []int64) (map[int64][]productFile, error) {
	out := map[int64][]productFile{}
	if len(ids) == 0 {
		return out, nil
	}
	rows, err := h.c.DB.QueryContext(ctx, "SELECT base_variants_product_files.base_variant_id, product_files.id, product_files.filetype,"+
		" product_files.size FROM product_files"+
		" INNER JOIN base_variants_product_files ON product_files.id = base_variants_product_files.product_file_id"+
		" WHERE base_variants_product_files.base_variant_id IN ("+placeholders(len(ids))+") AND product_files.deleted_at IS NULL",
		int64Args(ids)...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var owner int64
		var f productFile
		if err := rows.Scan(&owner, &f.id, &f.filetype, &f.size); err != nil {
			return nil, err
		}
		out[owner] = append(out[owner], f)
	}
	return out, rows.Err()
}

func variantIDs(options []*variantOption) []int64 {
	ids := make([]int64, len(options))
	for i, o := range options {
		ids[i] = o.id
	}
	return ids
}

func placeholders(n int) string {
	return strings.TrimSuffix(strings.Repeat("?, ", n), ", ")
}

func int64Args(ids []int64) []any {
	args := make([]any, len(ids))
	for i, id := range ids {
		args[i] = id
	}
	return args
}
