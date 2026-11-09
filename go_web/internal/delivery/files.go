// Package delivery is the part of UrlRedirect that decides which of a seller's files a buyer's
// link delivers, and the download page polls built on it. Every read issues the statement
// ActiveRecord issues, so rows MySQL may return in any order (no ORDER BY, or ties in one)
// come back as they do for Rails.
package delivery

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strconv"
	"strings"

	"github.com/antiwork/gumroad/go_web/internal/db"
	"github.com/antiwork/gumroad/go_web/internal/obfuscate"
	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// Link's has_flags masks: flag n is 1 << (n-1).
const (
	productIsPhysical                       = 1 << 7
	productHasSameRichContentForAllVariants = 1 << 24
)

// Redirect is the url_redirects columns AliveProductFiles reads.
type Redirect struct {
	ID                                                       int64
	PurchaseID, ProductID, InstallmentID, ImportedCustomerID *int64
}

// ProductFile is the product_files columns the polls read. Take it from AliveProductFiles:
// AudioDurations also needs what MySQL said about the filegroup.
type ProductFile struct {
	ID         int64
	Filetype   string // product_files.filetype ("" when NULL)
	Filegroup  string
	Pagelength *int64
	Duration   *int64
	// filegroup = 'audio' under the column's collation, as where(filegroup: "audio") matches
	// it: case-, accent- and trailing-space-insensitive, unlike listenable?.
	audio bool
}

// AliveProductFiles is UrlRedirect#alive_product_files: the rows and order Rails returns,
// including the repeats a duplicated base_variants_product_files row gives it. ids decrypts
// the file embeds in the rich content that picks the files.
func AliveProductFiles(ctx context.Context, conn *sql.DB, r *Redirect, ids *obfuscate.IDs) ([]ProductFile, error) {
	return newLoader(ctx, conn, r, ids).aliveProductFiles()
}

func newLoader(ctx context.Context, conn *sql.DB, r *Redirect, ids *obfuscate.IDs) *loader {
	return &loader{ctx: ctx, conn: conn, r: r, ids: ids, products: map[int64]*product{}, categories: map[int64]*category{},
		categoryHasFiles: map[int64]bool{}, contents: map[contentOwner][]*RichContent{}}
}

type product struct {
	id    int64
	flags int64

	aliveVariants       []*variant
	aliveVariantsLoaded bool
}

func (p *product) is(mask int64) bool { return p.flags&mask != 0 }

type variantClass int

const (
	classBaseVariant variantClass = iota // a blank type, which instantiates BaseVariant itself
	classVariant
	classSku
)

type variant struct {
	id         int64
	class      variantClass
	categoryID sql.NullInt64
	productID  sql.NullInt64
	deleted    bool
	// priceDifferenceCents is NULL-as-0, as Ruby's to_i reads it.
	priceDifferenceCents int64
}

// owner is what with_product_files and rich_content_provider return.
type owner struct {
	product     *product
	variant     *variant
	installment bool
}

type installment struct {
	id        int64
	productID sql.NullInt64
}

type purchase struct {
	id        int64
	productID sql.NullInt64
}

type category struct {
	id        int64
	productID sql.NullInt64
}

// contentOwner is rich_contents' polymorphic entity: a BaseVariant subclass is stored as BaseVariant.
type contentOwner struct {
	entityType string
	id         int64
}

// loader reads each row once per call, as UrlRedirect's memoized associations do.
type loader struct {
	ctx  context.Context
	conn *sql.DB
	r    *Redirect
	ids  *obfuscate.IDs

	installment             *installment
	installmentLoaded       bool
	installmentHasFiles     bool
	installmentFilesChecked bool
	purchase                *purchase
	purchaseLoaded          bool
	variantAttributes       []*variant
	variantsLoaded          bool
	referencedProduct       *product
	referencedProductLoaded bool
	provider                *owner
	providerLoaded          bool

	// display reads the files as download_attributes does: every column, ordered once more
	// by position, so ties fall as they do for its SELECT product_files.*.
	display   bool
	displayed []*displayFile

	products         map[int64]*product // nil for a missing row
	categories       map[int64]*category
	categoryHasFiles map[int64]bool
	contents         map[contentOwner][]*RichContent
}

const (
	fileColumns = "SELECT `product_files`.`id`, `product_files`.`filetype`, `product_files`.`filegroup`, " +
		"`product_files`.`pagelength`, `product_files`.`duration`, `product_files`.`filegroup` = 'audio' FROM `product_files`"
	// The habtm join every BaseVariant#product_files query goes through.
	variantFilesJoin = " INNER JOIN `base_variants_product_files` ON `product_files`.`id` = `base_variants_product_files`.`product_file_id`" +
		" WHERE `base_variants_product_files`.`base_variant_id` = ? AND `product_files`.`deleted_at` IS NULL"
	inPosition = " ORDER BY `product_files`.`position` ASC"

	variantColumns = "SELECT `base_variants`.`id`, `base_variants`.`type`, `base_variants`.`variant_category_id`, " +
		"`base_variants`.`link_id`, `base_variants`.`deleted_at`, `base_variants`.`price_difference_cents` FROM `base_variants`"
	variantAttributesJoin = " INNER JOIN `base_variants_purchases` ON `base_variants`.`id` = `base_variants_purchases`.`base_variant_id`" +
		" WHERE `base_variants_purchases`.`purchase_id` = ?"
	// Link#alive_variants.
	aliveVariantsJoin = " INNER JOIN `variant_categories` ON `base_variants`.`variant_category_id` = `variant_categories`.`id`" +
		" WHERE `base_variants`.`type` = 'Variant' AND `variant_categories`.`link_id` = ? AND `variant_categories`.`deleted_at` IS NULL" +
		" AND `base_variants`.`deleted_at` IS NULL"
)

func (l *loader) aliveProductFiles() ([]ProductFile, error) {
	hasFiles, err := l.installmentWithFiles()
	if err != nil {
		return nil, err
	}
	if hasFiles {
		return l.files(fileColumns+" WHERE `product_files`.`installment_id` = ? AND `product_files`.`deleted_at` IS NULL"+inPosition, l.installment.id)
	}

	provider, err := l.richContentProvider()
	if err != nil {
		return nil, err
	}
	if provider != nil {
		return l.providerFiles(provider)
	}

	p, err := l.loadPurchase()
	if err != nil {
		return nil, err
	}
	if p != nil {
		withFiles, err := l.hasPurchasedVariantsFromCategoriesWithFiles()
		if err != nil {
			return nil, err
		}
		if withFiles {
			return l.purchasedVariantFiles()
		}
	}

	prod, err := l.loadReferencedProduct()
	if err != nil || prod == nil {
		return nil, err
	}
	return l.files(fileColumns+" WHERE `product_files`.`link_id` = ? AND `product_files`.`deleted_at` IS NULL"+inPosition, prod.id)
}

// providerFiles is the rich content provider's alive files: those its alive pages embed, in
// embed order, or all of them by position when the pages embed none.
func (l *loader) providerFiles(provider *owner) ([]ProductFile, error) {
	contents, err := l.contentsOf(provider)
	if err != nil {
		return nil, err
	}
	var embedded []int64
	for _, c := range contents {
		ids, err := c.embeddedProductFileIDsInOrder(l.ids)
		if err != nil {
			return nil, err
		}
		embedded = append(embedded, ids...)
	}
	embedded = uniq(embedded)

	var query string
	var args []any
	if provider.variant != nil {
		query, args = fileColumns+variantFilesJoin, []any{provider.variant.id}
	} else {
		query, args = fileColumns+" WHERE `product_files`.`link_id` = ? AND `product_files`.`deleted_at` IS NULL", []any{provider.product.id}
	}
	if len(embedded) == 0 {
		return l.files(query+inPosition, args...)
	}
	marks := placeholders(len(embedded))
	for _, id := range embedded {
		args = append(args, id)
	}
	// ordered_by_ids quotes each id, so FIELD compares them with the integer column as doubles.
	for _, id := range embedded {
		args = append(args, strconv.FormatInt(id, 10))
	}
	return l.files(query+" AND `product_files`.`id` IN ("+marks+") ORDER BY FIELD(product_files.id, "+marks+")", args...)
}

// purchasedVariantFiles is the branch for a purchase whose variants have files but whose
// redirect has no rich content provider, which only a row deleted mid-request leaves.
func (l *loader) purchasedVariantFiles() ([]ProductFile, error) {
	variants, err := l.loadVariantAttributes()
	if err != nil {
		return nil, err
	}
	var ids []int64
	for _, v := range variants {
		rows, err := l.conn.QueryContext(l.ctx, "SELECT `product_files`.`id` FROM `product_files`"+variantFilesJoin, v.id)
		if err != nil {
			return nil, err
		}
		for rows.Next() {
			var id int64
			if err := rows.Scan(&id); err != nil {
				rows.Close()
				return nil, err
			}
			ids = append(ids, id)
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return nil, err
		}
	}
	ids = uniq(ids)
	if len(ids) == 0 {
		return nil, nil
	}
	args := make([]any, len(ids))
	for i, id := range ids {
		args[i] = id
	}
	return l.files(fileColumns+" WHERE `product_files`.`id` IN ("+placeholders(len(ids))+")"+inPosition, args...)
}

func (l *loader) files(query string, args ...any) ([]ProductFile, error) {
	if l.display {
		return l.displayFiles(strings.Replace(query, fileColumns, displayColumns, 1)+", `product_files`.`position` ASC", args...)
	}
	rows, err := l.conn.QueryContext(l.ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var files []ProductFile
	for rows.Next() {
		var f ProductFile
		var filetype, filegroup sql.NullString
		var pagelength, duration sql.NullInt64
		var audio sql.NullBool
		if err := rows.Scan(&f.ID, &filetype, &filegroup, &pagelength, &duration, &audio); err != nil {
			return nil, err
		}
		f.Filetype, f.Filegroup, f.audio = filetype.String, filegroup.String, audio.Bool
		if pagelength.Valid {
			f.Pagelength = &pagelength.Int64
		}
		if duration.Valid {
			f.Duration = &duration.Int64
		}
		files = append(files, f)
	}
	return files, rows.Err()
}

// richContentProvider is UrlRedirect#rich_content_provider.
func (l *loader) richContentProvider() (*owner, error) {
	if l.providerLoaded {
		return l.provider, nil
	}
	provider, err := l.resolveRichContentProvider()
	if err != nil {
		return nil, err
	}
	l.provider, l.providerLoaded = provider, true
	return provider, nil
}

func (l *loader) resolveRichContentProvider() (*owner, error) {
	entity, err := l.withProductFiles()
	if err != nil || entity == nil || entity.installment {
		return nil, err
	}
	if entity.variant != nil {
		// should_refer_to_product_level_rich_content_of_purchased_variant?, whose product is
		// also entity.link.
		product, err := l.owningProduct(entity.variant)
		if err != nil {
			return nil, err
		}
		if product != nil && product.is(productHasSameRichContentForAllVariants) {
			recoverable, err := l.recoverableHiddenVariantRichContent(product)
			if err != nil {
				return nil, err
			}
			if !recoverable {
				return &owner{product: product}, nil
			}
		}
		if !entity.variant.deleted {
			return entity, nil
		}
	}
	return l.productOrCheapestVariant(entity)
}

// withProductFiles is UrlRedirect#with_product_files.
func (l *loader) withProductFiles() (*owner, error) {
	hasFiles, err := l.installmentWithFiles()
	if err != nil {
		return nil, err
	}
	if hasFiles {
		return &owner{installment: true}, nil
	}
	purchasedVariant, err := l.hasPurchasedVariantsFromCategoriesWithFiles()
	if err == nil && !purchasedVariant {
		purchasedVariant, err = l.hasPurchasedVariantsFromCategoriesWithRichContent()
	}
	if err != nil {
		return nil, err
	}
	if !purchasedVariant {
		prod, err := l.loadReferencedProduct()
		if err != nil || prod == nil {
			return nil, err
		}
		return &owner{product: prod}, nil
	}
	// purchase.variant_attributes.order(deleted_at: :asc).first: an alive variant first, and
	// among several the one MySQL's sort picks for the LIMIT.
	v, err := l.scanVariant(l.conn.QueryRowContext(l.ctx, variantColumns+variantAttributesJoin+
		" ORDER BY `base_variants`.`deleted_at` ASC LIMIT 1", l.purchase.id).Scan, false)
	if err != nil || v == nil {
		return nil, err
	}
	return &owner{variant: v}, nil
}

// hasPurchasedVariantsFromCategoriesWithRichContent is the UrlRedirect method of that name.
func (l *loader) hasPurchasedVariantsFromCategoriesWithRichContent() (bool, error) {
	p, err := l.loadPurchase()
	if err != nil || p == nil {
		return false, err
	}
	variants, err := l.loadVariantAttributes()
	if err != nil {
		return false, err
	}
	for _, v := range variants {
		if v.class == classVariant {
			return true, nil
		}
	}
	return false, nil
}

// productOrCheapestVariant is UrlRedirect#product_or_cheapest_variant_as_rich_content_provider.
func (l *loader) productOrCheapestVariant(entity *owner) (*owner, error) {
	product := entity.product
	if entity.variant != nil {
		var err error
		if product, err = l.owningProduct(entity.variant); err != nil {
			return nil, err
		}
	}
	if product == nil {
		return entity, nil
	}
	hasProductLevelContent, err := l.anyEditorContent(contentOwner{"Link", product.id})
	if err != nil {
		return nil, err
	}
	effectivelyShared := false
	if product.is(productHasSameRichContentForAllVariants) {
		recoverable, err := l.recoverableHiddenVariantRichContent(product)
		if err != nil {
			return nil, err
		}
		effectivelyShared = !recoverable
	}
	if product.is(productIsPhysical) || effectivelyShared || hasProductLevelContent {
		return &owner{product: product}, nil
	}
	none, err := l.aliveVariantsNone(product)
	if err != nil {
		return nil, err
	}
	if none {
		return &owner{product: product}, nil
	}

	cheapestFirst := variantColumns + aliveVariantsJoin + " ORDER BY `base_variants`.`price_difference_cents` ASC"
	recoverable, err := l.recoverableHiddenVariantRichContent(product)
	if err != nil {
		return nil, err
	}
	if !recoverable && entity.variant != nil {
		variants, err := l.variants(cheapestFirst, true, product.id)
		if err != nil {
			return nil, err
		}
		if v := closestPriced(variants, entity.variant.priceDifferenceCents); v != nil {
			return &owner{variant: v}, nil
		}
		return nil, nil
	}
	if !recoverable {
		// An unloaded relation's first is its own LIMIT 1 query, whose pick among equal prices
		// can differ from the full sort's.
		v, err := l.scanVariant(l.conn.QueryRowContext(l.ctx, cheapestFirst+" LIMIT 1", product.id).Scan, true)
		if err != nil || v == nil {
			return nil, err
		}
		return &owner{variant: v}, nil
	}
	variants, err := l.variants(cheapestFirst, true, product.id)
	if err != nil {
		return nil, err
	}
	for _, v := range variants {
		has, err := l.anyEditorContent(contentOwner{"BaseVariant", v.id})
		if err != nil {
			return nil, err
		}
		if has {
			return &owner{variant: v}, nil
		}
	}
	if len(variants) == 0 {
		return nil, nil
	}
	return &owner{variant: variants[0]}, nil
}

// closestPriced is the min_by on [|price - target|, price, id] that picks a deleted variant's replacement.
func closestPriced(variants []*variant, target int64) *variant {
	var best *variant
	for _, v := range variants {
		if best == nil || closerThan(v, best, target) {
			best = v
		}
	}
	return best
}

func closerThan(a, b *variant, target int64) bool {
	distA, distB := absDiff(a.priceDifferenceCents, target), absDiff(b.priceDifferenceCents, target)
	if distA != distB {
		return distA < distB
	}
	if a.priceDifferenceCents != b.priceDifferenceCents {
		return a.priceDifferenceCents < b.priceDifferenceCents
	}
	return a.id < b.id
}

func absDiff(a, b int64) int64 {
	if a > b {
		return a - b
	}
	return b - a
}

// recoverableHiddenVariantRichContent is Link#recoverable_hidden_variant_rich_content?.
func (l *loader) recoverableHiddenVariantRichContent(p *product) (bool, error) {
	if !p.is(productHasSameRichContentForAllVariants) || p.is(productIsPhysical) {
		return false, nil
	}
	has, err := l.anyEditorContent(contentOwner{"Link", p.id})
	if err != nil || has {
		return false, err
	}
	if !p.aliveVariantsLoaded {
		if p.aliveVariants, err = l.variants(variantColumns+aliveVariantsJoin, true, p.id); err != nil {
			return false, err
		}
		p.aliveVariantsLoaded = true
	}
	for _, v := range p.aliveVariants {
		has, err := l.anyEditorContent(contentOwner{"BaseVariant", v.id})
		if err != nil || has {
			return has, err
		}
	}
	return false, nil
}

// aliveVariantsNone is product.alive_variants.none?, which reads the loaded association or
// asks MySQL without instantiating a row.
func (l *loader) aliveVariantsNone(p *product) (bool, error) {
	if p.aliveVariantsLoaded {
		return len(p.aliveVariants) == 0, nil
	}
	found, err := l.exists("SELECT 1 AS one FROM `base_variants`"+aliveVariantsJoin+" LIMIT 1", p.id)
	return !found, err
}

// owningProduct is BaseVariant#owning_product.
func (l *loader) owningProduct(v *variant) (*product, error) {
	switch v.class {
	case classVariant:
		c, err := l.loadCategory(v.categoryID)
		if err != nil || c == nil {
			return nil, err
		}
		return l.loadProduct(c.productID)
	case classSku:
		return l.loadProduct(v.productID)
	}
	return nil, fmt.Errorf("delivery: base variant %d has no type, and BaseVariant has no #link", v.id)
}

// hasPurchasedVariantsFromCategoriesWithFiles is the UrlRedirect method of that name.
func (l *loader) hasPurchasedVariantsFromCategoriesWithFiles() (bool, error) {
	p, err := l.loadPurchase()
	if err != nil || p == nil {
		return false, err
	}
	variants, err := l.loadVariantAttributes()
	if err != nil {
		return false, err
	}
	for _, v := range variants {
		if v.class != classVariant {
			continue
		}
		has, err := l.exists("SELECT 1 AS one FROM `product_files`"+variantFilesJoin+" LIMIT 1", v.id)
		if err != nil || has {
			return has, err
		}
		c, err := l.loadCategory(v.categoryID)
		if err != nil {
			return false, err
		}
		if c == nil {
			continue
		}
		if has, err = l.categoryHasVariantWithFiles(c.id); err != nil || has {
			return has, err
		}
	}
	return false, nil
}

// categoryHasVariantWithFiles is variant_category.variants.alive.any?(&:has_files?), which
// instantiates every alive variant before asking each for files.
func (l *loader) categoryHasVariantWithFiles(categoryID int64) (bool, error) {
	if has, ok := l.categoryHasFiles[categoryID]; ok {
		return has, nil
	}
	rows, err := l.conn.QueryContext(l.ctx, "SELECT `base_variants`.`id`, `base_variants`.`type`, EXISTS (SELECT 1 FROM `product_files`"+
		" INNER JOIN `base_variants_product_files` ON `product_files`.`id` = `base_variants_product_files`.`product_file_id`"+
		" WHERE `base_variants_product_files`.`base_variant_id` = `base_variants`.`id` AND `product_files`.`deleted_at` IS NULL)"+
		" FROM `base_variants` WHERE `base_variants`.`type` = 'Variant' AND `base_variants`.`variant_category_id` = ?"+
		" AND `base_variants`.`deleted_at` IS NULL", categoryID)
	if err != nil {
		return false, err
	}
	defer rows.Close()
	has := false
	for rows.Next() {
		var id int64
		var typ sql.NullString
		var hasFiles bool
		if err := rows.Scan(&id, &typ, &hasFiles); err != nil {
			return false, err
		}
		if _, err := variantClassOf(id, typ, true); err != nil {
			return false, err
		}
		has = has || hasFiles
	}
	if err := rows.Err(); err != nil {
		return false, err
	}
	l.categoryHasFiles[categoryID] = has
	return has, nil
}

func (l *loader) installmentWithFiles() (bool, error) {
	if l.installmentFilesChecked {
		return l.installmentHasFiles, nil
	}
	inst, err := l.loadInstallment()
	if err != nil {
		return false, err
	}
	if inst != nil {
		// Installment#has_files?
		has, err := l.exists("SELECT 1 AS one FROM `product_files` WHERE `product_files`.`installment_id` = ? AND `product_files`.`deleted_at` IS NULL LIMIT 1", inst.id)
		if err != nil {
			return false, err
		}
		l.installmentHasFiles = has
	}
	l.installmentFilesChecked = true
	return l.installmentHasFiles, nil
}

func (l *loader) loadInstallment() (*installment, error) {
	if l.installmentLoaded {
		return l.installment, nil
	}
	if l.r.InstallmentID != nil {
		i := &installment{}
		found, err := l.queryRow("SELECT `installments`.`id`, `installments`.`link_id` FROM `installments` WHERE `installments`.`id` = ? LIMIT 1",
			[]any{*l.r.InstallmentID}, &i.id, &i.productID)
		if err != nil {
			return nil, err
		}
		if found {
			l.installment = i
		}
	}
	l.installmentLoaded = true
	return l.installment, nil
}

func (l *loader) loadPurchase() (*purchase, error) {
	if l.purchaseLoaded {
		return l.purchase, nil
	}
	if l.r.PurchaseID != nil {
		p := &purchase{}
		found, err := l.queryRow("SELECT `purchases`.`id`, `purchases`.`link_id` FROM `purchases` WHERE `purchases`.`id` = ? LIMIT 1",
			[]any{*l.r.PurchaseID}, &p.id, &p.productID)
		if err != nil {
			return nil, err
		}
		if found {
			l.purchase = p
		}
	}
	l.purchaseLoaded = true
	return l.purchase, nil
}

// loadVariantAttributes is the purchase's habtm variant_attributes, in the unordered query's order.
func (l *loader) loadVariantAttributes() ([]*variant, error) {
	if l.variantsLoaded {
		return l.variantAttributes, nil
	}
	variants, err := l.variants(variantColumns+variantAttributesJoin, false, l.purchase.id)
	if err != nil {
		return nil, err
	}
	l.variantAttributes, l.variantsLoaded = variants, true
	return variants, nil
}

// loadReferencedProduct is UrlRedirect#referenced_link.
func (l *loader) loadReferencedProduct() (*product, error) {
	if l.referencedProductLoaded {
		return l.referencedProduct, nil
	}
	prod, err := l.resolveReferencedProduct()
	if err != nil {
		return nil, err
	}
	l.referencedProduct, l.referencedProductLoaded = prod, true
	return prod, nil
}

func (l *loader) resolveReferencedProduct() (*product, error) {
	p, err := l.loadPurchase()
	if err != nil {
		return nil, err
	}
	if p != nil {
		return l.loadProduct(p.productID)
	}
	if l.r.ImportedCustomerID != nil {
		var productID sql.NullInt64
		found, err := l.queryRow("SELECT `imported_customers`.`link_id` FROM `imported_customers` WHERE `imported_customers`.`id` = ? LIMIT 1",
			[]any{*l.r.ImportedCustomerID}, &productID)
		if err != nil {
			return nil, err
		}
		if found {
			return l.loadProduct(productID)
		}
	}
	if l.r.ProductID != nil {
		prod, err := l.loadProduct(sql.NullInt64{Int64: *l.r.ProductID, Valid: true})
		if err != nil || prod != nil {
			return prod, err
		}
	}
	inst, err := l.loadInstallment()
	if err != nil || inst == nil {
		return nil, err
	}
	return l.loadProduct(inst.productID)
}

func (l *loader) loadProduct(id sql.NullInt64) (*product, error) {
	if !id.Valid {
		return nil, nil
	}
	if p, ok := l.products[id.Int64]; ok {
		return p, nil
	}
	p := &product{}
	found, err := l.queryRow("SELECT `links`.`id`, `links`.`flags` FROM `links` WHERE `links`.`id` = ? LIMIT 1", []any{id.Int64}, &p.id, &p.flags)
	if err != nil {
		return nil, err
	}
	if !found {
		p = nil
	}
	l.products[id.Int64] = p
	return p, nil
}

func (l *loader) loadCategory(id sql.NullInt64) (*category, error) {
	if !id.Valid {
		return nil, nil
	}
	if c, ok := l.categories[id.Int64]; ok {
		return c, nil
	}
	c := &category{}
	found, err := l.queryRow("SELECT `variant_categories`.`id`, `variant_categories`.`link_id` FROM `variant_categories` WHERE `variant_categories`.`id` = ? LIMIT 1",
		[]any{id.Int64}, &c.id, &c.productID)
	if err != nil {
		return nil, err
	}
	if !found {
		c = nil
	}
	l.categories[id.Int64] = c
	return c, nil
}

func (l *loader) contentsOf(o *owner) ([]*RichContent, error) {
	if o.variant != nil {
		return l.aliveRichContents(contentOwner{"BaseVariant", o.variant.id})
	}
	return l.aliveRichContents(contentOwner{"Link", o.product.id})
}

// aliveRichContents is the entity's alive_rich_contents, in the unordered query's order.
func (l *loader) aliveRichContents(key contentOwner) ([]*RichContent, error) {
	if contents, ok := l.contents[key]; ok {
		return contents, nil
	}
	rows, err := l.conn.QueryContext(l.ctx, "SELECT `rich_contents`.`id`, `rich_contents`.`title`, `rich_contents`.`description`,"+
		" `rich_contents`.`updated_at`, `rich_contents`.`position` FROM `rich_contents`"+
		" WHERE `rich_contents`.`entity_id` = ? AND `rich_contents`.`entity_type` = ? AND `rich_contents`.`deleted_at` IS NULL", key.id, key.entityType)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	contents := []*RichContent{}
	for rows.Next() {
		c := &RichContent{}
		if err := rows.Scan(&c.id, &c.Title, &c.DescriptionJSON, &c.updatedAt, &c.position); err != nil {
			return nil, err
		}
		contents = append(contents, c)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	l.contents[key] = contents
	return contents, nil
}

// anyEditorContent is entity.alive_rich_contents.any?(&:has_editor_content?), stopping where Ruby does.
func (l *loader) anyEditorContent(key contentOwner) (bool, error) {
	contents, err := l.aliveRichContents(key)
	if err != nil {
		return false, err
	}
	for _, c := range contents {
		has, err := c.HasEditorContent()
		if err != nil || has {
			return has, err
		}
	}
	return false, nil
}

func (l *loader) variants(query string, asVariant bool, args ...any) ([]*variant, error) {
	rows, err := l.conn.QueryContext(l.ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var variants []*variant
	for rows.Next() {
		v, err := l.scanVariant(rows.Scan, asVariant)
		if err != nil {
			return nil, err
		}
		variants = append(variants, v)
	}
	return variants, rows.Err()
}

// scanVariant instantiates a base_variants row; it is nil for no row.
func (l *loader) scanVariant(scan func(...any) error, asVariant bool) (*variant, error) {
	v := &variant{}
	var typ sql.NullString
	var deletedAt db.NullTime
	var price sql.NullInt64
	err := scan(&v.id, &typ, &v.categoryID, &v.productID, &deletedAt, &price)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if v.class, err = variantClassOf(v.id, typ, asVariant); err != nil {
		return nil, err
	}
	v.deleted = deletedAt.Valid
	v.priceDifferenceCents = price.Int64
	return v, nil
}

// variantClassOf is ActiveRecord's STI lookup for a base_variants row loaded through BaseVariant,
// or through Variant when asVariant. The query's type = 'Variant' matches under the column's
// collation, so a 'variant' or 'Variant ' row reaches here and fails to constantize, as in Ruby.
func variantClassOf(id int64, typ sql.NullString, asVariant bool) (variantClass, error) {
	if asVariant {
		if typ.Valid && typ.String == "Variant" {
			return classVariant, nil
		}
	} else {
		switch {
		case !typ.Valid || !rails.Present(typ.String) || typ.String == "BaseVariant":
			return classBaseVariant, nil
		case typ.String == "Variant":
			return classVariant, nil
		case typ.String == "Sku":
			return classSku, nil
		}
	}
	return 0, fmt.Errorf("delivery: base variant %d has type %q, which is not a single-table inheritance subclass here", id, typ.String)
}

func (l *loader) queryRow(query string, args []any, dest ...any) (bool, error) {
	err := l.conn.QueryRowContext(l.ctx, query, args...).Scan(dest...)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

func (l *loader) exists(query string, args ...any) (bool, error) {
	var one int
	return l.queryRow(query, args, &one)
}

func placeholders(n int) string {
	return "?" + strings.Repeat(", ?", n-1)
}
