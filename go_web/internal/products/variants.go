package products

import (
	"context"
	"database/sql"
	"strings"

	"github.com/antiwork/gumroad/go_web/internal/db"
	"github.com/antiwork/gumroad/go_web/internal/delivery"
	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// variantOption is an alive Variant, as BaseVariant#to_option reads it.
type variantOption struct {
	id, categoryID                     int64
	externalID                         string
	name, description                  sql.NullString
	maxPurchaseCount, sold             sql.NullInt64
	priceDifference, durationInMinutes sql.NullInt64
	customizablePrice                  sql.NullBool
	position                           sql.NullInt64
	createdAt                          db.NullTime
}

// quantityLeft is BaseVariant#quantity_left, with the counter read with the row.
func (o *variantOption) quantityLeft() *int64 {
	if !o.maxPurchaseCount.Valid {
		return nil
	}
	n := max(o.maxPurchaseCount.Int64-o.sold.Int64, 0)
	return &n
}

// variants are the product's alive categories and Variants. Tier categories, memberships and
// SKUs are Rails'.
type variants struct {
	categories []int64
	// options is option_records: the first category's Variants, in_order.
	options []*variantOption
	all     []*variantOption
}

// loadVariants reads every alive category and Variant. Rails takes the first category in
// MySQL's order, which for this index is id order.
func (h *handler) loadVariants(ctx context.Context, prod *product) (*variants, error) {
	vs := &variants{}
	rows, err := h.c.DB.QueryContext(ctx, "SELECT variant_categories.id FROM variant_categories"+
		" WHERE variant_categories.deleted_at IS NULL AND variant_categories.link_id = ? ORDER BY variant_categories.id", prod.id)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return nil, err
		}
		vs.categories = append(vs.categories, id)
	}
	rows.Close()
	if err := rows.Err(); err != nil || len(vs.categories) == 0 {
		return vs, err
	}
	rows, err = h.c.DB.QueryContext(ctx, "SELECT base_variants.id, base_variants.variant_category_id, base_variants.name,"+
		" base_variants.description, base_variants.max_purchase_count, base_variants.sales_count_for_inventory_cache,"+
		" base_variants.price_difference_cents, base_variants.duration_in_minutes, base_variants.customizable_price,"+
		" base_variants.position_in_category, base_variants.created_at FROM base_variants"+
		" INNER JOIN variant_categories ON base_variants.variant_category_id = variant_categories.id"+
		" WHERE base_variants.type = 'Variant' AND variant_categories.link_id = ? AND variant_categories.deleted_at IS NULL"+
		" AND base_variants.deleted_at IS NULL"+
		" ORDER BY base_variants.position_in_category ASC, base_variants.created_at ASC, base_variants.id ASC", prod.id)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		o := &variantOption{}
		if err := rows.Scan(&o.id, &o.categoryID, &o.name, &o.description, &o.maxPurchaseCount, &o.sold, &o.priceDifference,
			&o.durationInMinutes, &o.customizablePrice, &o.position, &o.createdAt); err != nil {
			return nil, err
		}
		o.externalID = h.c.IDs.Encrypt(o.id)
		vs.all = append(vs.all, o)
		if o.categoryID == vs.categories[0] {
			if n := len(vs.options); n > 0 && sameOrder(vs.options[n-1], o) {
				// in_order leaves ties to MySQL.
				return nil, fallback("variant order")
			}
			vs.options = append(vs.options, o)
		}
	}
	return vs, rows.Err()
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
			if q := o.quantityLeft(); q == nil || *q > 0 {
				available = true
			}
		}
		if !alive || available {
			return true
		}
	}
	return false
}

// optionsProps is Link#options: to_option for each, without a membership's recurrence prices.
func (h *handler) optionsProps(prod *product, vs *variants) []any {
	out := make([]any, 0, len(vs.options))
	for _, o := range vs.options {
		name := o.name.String
		if name == "Untitled" {
			name = prod.name
		}
		out = append(out, rails.NewRHash().
			Sym("id", o.externalID).
			Sym("name", name).
			Sym("quantity_left", intOrNil(o.quantityLeft())).
			Sym("description", o.description.String).
			Sym("price_difference_cents", nullInt(o.priceDifference)).
			Sym("recurrence_price_values", nil).
			Sym("is_pwyw", o.customizablePrice.Bool).
			Sym("duration_in_minutes", nullInt(o.durationInMinutes)))
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
