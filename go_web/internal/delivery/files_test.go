package delivery

import (
	"context"
	"database/sql"
	"fmt"
	"slices"
	"strings"
	"testing"

	"github.com/antiwork/gumroad/go_web/internal/obfuscate"
	"github.com/antiwork/gumroad/go_web/internal/session/testdb"
)

// This package's fixtures use ids from base up, inside testdb's range and clear of the
// 1_500_xxx ids other packages' tests insert while these run.
const (
	base    = int64(1_730_000)
	lastID  = base + 9_999
	joinIDs = base + 9_000 // join-table rows take ids from here
	stamp   = "2026-01-01 00:00:00"
)

var fixtureTables = []string{
	"links", "purchases", "installments", "imported_customers", "variant_categories", "base_variants",
	"base_variants_purchases", "base_variants_product_files", "product_files", "rich_contents", "media_locations",
}

type env struct {
	t     *testing.T
	db    *sql.DB
	ids   *obfuscate.IDs
	joins int64
}

func newEnv(t *testing.T) *env {
	t.Helper()
	db := testdb.Open(t)
	// Rows a killed run left behind would collide with this one's.
	for _, table := range fixtureTables {
		if _, err := db.Exec("DELETE FROM `"+table+"` WHERE id BETWEEN ? AND ?", base, lastID); err != nil {
			t.Fatal(err)
		}
	}
	return &env{t: t, db: db, ids: testIDs(t), joins: joinIDs}
}

func (e *env) insert(table string, id int64, columns map[string]any) {
	e.t.Helper()
	row := map[string]any{"id": id}
	for k, v := range columns {
		row[k] = v
	}
	testdb.Insert(e.t, e.db, table, row)
}

func (e *env) exec(query string, args ...any) {
	e.t.Helper()
	if _, err := e.db.Exec(query, args...); err != nil {
		e.t.Fatalf("%s: %v", query, err)
	}
}

func (e *env) insertProduct(id, flags int64) {
	e.insert("links", id, map[string]any{"name": "Product", "flags": flags, "created_at": stamp, "updated_at": stamp})
}

// file inserts a product file; columns override the defaults, and a position of nil is NULL.
func (e *env) file(id int64, columns map[string]any) {
	row := map[string]any{"filetype": "pdf", "filegroup": "document", "created_at": stamp, "updated_at": stamp}
	for k, v := range columns {
		row[k] = v
	}
	e.insert("product_files", id, row)
}

func (e *env) purchase(id, productID int64) {
	e.insert("purchases", id, map[string]any{"link_id": productID, "created_at": stamp})
}

func (e *env) category(id, productID int64) {
	e.insert("variant_categories", id, map[string]any{"link_id": productID, "title": "Version"})
}

// variant inserts an alive Variant in categoryID; columns override that.
func (e *env) variant(id, categoryID int64, columns map[string]any) {
	row := map[string]any{"variant_category_id": categoryID, "type": "Variant", "name": fmt.Sprint("Variant ", id)}
	for k, v := range columns {
		row[k] = v
	}
	e.insert("base_variants", id, row)
}

func (e *env) buys(purchaseID int64, variantIDs ...int64) {
	for _, id := range variantIDs {
		e.joins++
		e.insert("base_variants_purchases", e.joins, map[string]any{"purchase_id": purchaseID, "base_variant_id": id})
	}
}

func (e *env) attach(variantID int64, fileIDs ...int64) {
	for _, id := range fileIDs {
		e.joins++
		e.insert("base_variants_product_files", e.joins, map[string]any{"base_variant_id": variantID, "product_file_id": id})
	}
}

func (e *env) content(id int64, entityType string, entityID int64, description string) {
	e.insert("rich_contents", id, map[string]any{"entity_type": entityType, "entity_id": entityID,
		"description": description, "created_at": stamp, "updated_at": stamp})
}

// embedding is a page description that embeds fileIDs in order.
func (e *env) embedding(fileIDs ...int64) string {
	nodes := make([]string, len(fileIDs))
	for i, id := range fileIDs {
		nodes[i] = fmt.Sprintf(`{"type":"fileEmbed","attrs":{"id":%q,"uid":"u%d"}}`, e.ids.Encrypt(id), i)
	}
	return "[" + strings.Join(nodes, ",") + "]"
}

const textPage = `[{"type":"paragraph","content":[{"type":"text","text":"Read me"}]}]`
const blankPage = `[{"type":"paragraph"}]`

func (e *env) files(r *Redirect) ([]int64, error) {
	files, err := AliveProductFiles(context.Background(), e.db, r, e.ids)
	if err != nil {
		return nil, err
	}
	ids := make([]int64, len(files))
	for i, f := range files {
		ids[i] = f.ID
	}
	return ids, nil
}

func (e *env) expectFiles(r *Redirect, want ...int64) {
	e.t.Helper()
	got, err := e.files(r)
	if err != nil {
		e.t.Fatal(err)
	}
	if !slices.Equal(got, want) {
		e.t.Fatalf("alive_product_files = %v, want %v", offsets(got), offsets(want))
	}
}

func (e *env) expectError(r *Redirect, substring string) {
	e.t.Helper()
	got, err := e.files(r)
	if err == nil || !strings.Contains(err.Error(), substring) {
		e.t.Fatalf("alive_product_files = %v, %v; want an error with %q", offsets(got), err, substring)
	}
}

// offsets prints fixture ids relative to base.
func offsets(ids []int64) []int64 {
	out := make([]int64, len(ids))
	for i, id := range ids {
		out[i] = id - base
	}
	return out
}

func ptr(v int64) *int64 { return &v }

func TestInstallmentFilesWinWhileItHasAliveOnes(t *testing.T) {
	e := newEnv(t)
	product, installment, purchase := base+1, base+50, base+20
	e.insertProduct(product, 0)
	e.purchase(purchase, product)
	e.insert("installments", installment, map[string]any{"link_id": product, "created_at": stamp, "updated_at": stamp})
	e.file(base+100, map[string]any{"link_id": product, "position": 0})
	e.file(base+101, map[string]any{"installment_id": installment, "position": 2})
	e.file(base+102, map[string]any{"installment_id": installment, "position": nil})
	e.file(base+103, map[string]any{"installment_id": installment, "position": 1})
	e.file(base+104, map[string]any{"installment_id": installment, "position": 0, "deleted_at": stamp})
	r := &Redirect{ID: base, InstallmentID: ptr(installment), PurchaseID: ptr(purchase)}

	// position ASC puts NULL first, as MySQL does.
	e.expectFiles(r, base+102, base+103, base+101)

	e.exec("UPDATE product_files SET deleted_at = ? WHERE installment_id = ?", stamp, installment)
	e.expectFiles(r, base+100)
}

func TestEmbeddedFilesPickAndOrderTheProductsFiles(t *testing.T) {
	e := newEnv(t)
	product, other, purchase := base+1, base+2, base+20
	e.insertProduct(product, 0)
	e.insertProduct(other, 0)
	e.purchase(purchase, product)
	for i, position := range []any{3, 2, 1, 0} {
		e.file(base+100+int64(i), map[string]any{"link_id": product, "position": position})
	}
	e.exec("UPDATE product_files SET deleted_at = ? WHERE id = ?", stamp, base+103)
	e.file(base+110, map[string]any{"link_id": other})
	r := &Redirect{PurchaseID: ptr(purchase)}

	// Pages are read in the unordered query's order, embeds in document order, each file once;
	// a deleted file, another product's file, a deleted page and an id that does not decrypt
	// contribute nothing.
	e.content(base+200, "Link", product, fmt.Sprintf(`[%s,{"type":"fileEmbedGroup","content":[%s,{"type":"fileEmbed","attrs":{"id":"garbage"}}]},%s]`,
		strings.Trim(e.embedding(base+102), "[]"), strings.Trim(e.embedding(base+100), "[]"), strings.Trim(e.embedding(base+102), "[]")))
	e.content(base+201, "Link", product, fmt.Sprintf(`[{"type":"bulletList","content":[{"type":"listItem","content":%s}]},%s]`,
		e.embedding(base+103), strings.Trim(e.embedding(base+110, base+101, base+100), "[]")))
	e.content(base+202, "Link", product, e.embedding(base+101))
	e.exec("UPDATE rich_contents SET deleted_at = ? WHERE id = ?", stamp, base+202)
	e.expectFiles(r, base+102, base+100, base+101)

	// Without embeds the provider's files come in position order.
	e.exec("UPDATE rich_contents SET description = ? WHERE id IN (?, ?)", textPage, base+200, base+201)
	e.expectFiles(r, base+102, base+101, base+100)

	// An embed whose plaintext is not a number decrypts to 0, so the page still embeds a file:
	// none, rather than all of them.
	e.exec("UPDATE rich_contents SET description = ? WHERE id = ?", fmt.Sprintf(`[{"type":"fileEmbed","attrs":{"id":%q}}]`, encryptPlaintext("abc")), base+201)
	e.expectFiles(r)

	e.exec("UPDATE rich_contents SET description = ? WHERE id = ?", `[{"type":"fileEmbed","attrs":"oops"}]`, base+201)
	e.expectError(r, "has no #dig")
}

func TestRedirectsWithoutAProductDeliverNothing(t *testing.T) {
	e := newEnv(t)
	e.insertProduct(base+1, 0)
	e.file(base+100, map[string]any{"link_id": base + 1})
	e.expectFiles(&Redirect{})
	e.expectFiles(&Redirect{PurchaseID: ptr(base + 20), ProductID: ptr(base + 2)})

	// A purchase whose product is gone refers to nothing; referenced_link does not fall through.
	e.purchase(base+21, base+3)
	e.insert("imported_customers", base+30, map[string]any{"link_id": base + 1, "created_at": stamp, "updated_at": stamp})
	e.expectFiles(&Redirect{PurchaseID: ptr(base + 21), ImportedCustomerID: ptr(base + 30)})
}

func TestReferencedProductFallsBackThroughTheRedirectsAssociations(t *testing.T) {
	e := newEnv(t)
	e.insertProduct(base+1, 0)
	e.insertProduct(base+2, 0)
	e.file(base+100, map[string]any{"link_id": base + 1})
	e.file(base+101, map[string]any{"link_id": base + 2})
	e.insert("imported_customers", base+30, map[string]any{"link_id": base + 1, "created_at": stamp, "updated_at": stamp})
	e.insert("installments", base+50, map[string]any{"link_id": base + 2, "created_at": stamp, "updated_at": stamp})

	e.expectFiles(&Redirect{PurchaseID: ptr(base + 20), ImportedCustomerID: ptr(base + 30), ProductID: ptr(base + 2)}, base+100)
	e.expectFiles(&Redirect{ImportedCustomerID: ptr(base + 31), ProductID: ptr(base + 2)}, base+101)
	// An installment without files hands over to its product, after a missing link.
	e.expectFiles(&Redirect{ProductID: ptr(base + 3), InstallmentID: ptr(base + 50)}, base+101)
}

// variantProduct is a product with product-level file 100, a category, and variants 10 and 11
// whose files are 101-103.
func variantProduct(e *env, flags int64) (product, purchase int64) {
	product, purchase = base+1, base+20
	e.insertProduct(product, flags)
	e.category(base+5, product)
	e.variant(base+10, base+5, map[string]any{"price_difference_cents": 0})
	e.variant(base+11, base+5, map[string]any{"price_difference_cents": 100})
	e.file(base+100, map[string]any{"link_id": product, "position": 0})
	e.file(base+101, map[string]any{"link_id": product, "position": 2})
	e.file(base+102, map[string]any{"link_id": product, "position": 1})
	e.file(base+103, map[string]any{"link_id": product, "position": 3})
	e.attach(base+10, base+103)
	e.attach(base+11, base+101, base+102)
	e.purchase(purchase, product)
	return product, purchase
}

func TestAPurchasedVariantDeliversItsOwnFiles(t *testing.T) {
	e := newEnv(t)
	_, purchase := variantProduct(e, 0)
	e.buys(purchase, base+11)
	r := &Redirect{PurchaseID: ptr(purchase)}
	e.expectFiles(r, base+102, base+101)

	// The habtm join repeats a file it lists twice, as ActiveRecord's query does.
	e.attach(base+11, base+102)
	e.expectFiles(r, base+102, base+102, base+101)

	e.content(base+200, "BaseVariant", base+11, e.embedding(base+101))
	e.expectFiles(r, base+101)
	// A product-level embed does not reach the variant's files.
	e.content(base+201, "Link", base+1, e.embedding(base+100))
	e.expectFiles(r, base+101)
}

func TestSharedContentMakesTheProductTheProvider(t *testing.T) {
	e := newEnv(t)
	product, purchase := variantProduct(e, productHasSameRichContentForAllVariants)
	e.buys(purchase, base+11)
	r := &Redirect{PurchaseID: ptr(purchase)}
	e.content(base+200, "Link", product, textPage)
	e.expectFiles(r, base+100, base+102, base+101, base+103)

	// A blank shared page while the variant has real pages is the recoverable hidden state:
	// the purchased variant keeps its own files.
	e.exec("UPDATE rich_contents SET description = ? WHERE id = ?", blankPage, base+200)
	e.content(base+201, "BaseVariant", base+11, textPage)
	e.expectFiles(r, base+102, base+101)

	// Another alive variant's pages make the state recoverable just the same.
	e.exec("UPDATE rich_contents SET entity_id = ? WHERE id = ?", base+10, base+201)
	e.expectFiles(r, base+102, base+101)

	// Without real variant pages the blank shared level still wins.
	e.exec("UPDATE rich_contents SET description = ? WHERE id = ?", blankPage, base+201)
	e.expectFiles(r, base+100, base+102, base+101, base+103)

	// A physical product's shared flag is never a recoverable lie.
	e.exec("UPDATE rich_contents SET description = ? WHERE id = ?", textPage, base+201)
	e.exec("UPDATE links SET flags = ? WHERE id = ?", productHasSameRichContentForAllVariants|productIsPhysical, product)
	e.expectFiles(r, base+100, base+102, base+101, base+103)
}

func TestTheProductFallsToItsCheapestVariant(t *testing.T) {
	e := newEnv(t)
	product, purchase := variantProduct(e, 0)
	r := &Redirect{PurchaseID: ptr(purchase)}
	// No purchased variant: the product, which has variants and no pages of its own.
	e.expectFiles(r, base+103)

	// A NULL price sorts first.
	e.variant(base+12, base+5, map[string]any{"price_difference_cents": nil})
	e.file(base+104, map[string]any{"link_id": product})
	e.attach(base+12, base+104)
	e.expectFiles(r, base+104)

	// Deleted variants and variants of a deleted category don't count.
	e.exec("UPDATE base_variants SET deleted_at = ? WHERE id = ?", stamp, base+12)
	e.exec("UPDATE base_variants SET variant_category_id = ? WHERE id = ?", base+6, base+10)
	e.category(base+6, product)
	e.exec("UPDATE variant_categories SET deleted_at = ? WHERE id = ?", stamp, base+6)
	e.expectFiles(r, base+102, base+101)

	// Product-level pages with content keep the product; a blank placeholder page doesn't.
	// File 104 has no position, so it leads the product's files.
	e.content(base+200, "Link", product, blankPage)
	e.expectFiles(r, base+102, base+101)
	e.exec("UPDATE rich_contents SET title = 'Welcome' WHERE id = ?", base+200)
	e.expectFiles(r, base+104, base+100, base+102, base+101, base+103)
	e.exec("UPDATE rich_contents SET deleted_at = ? WHERE id = ?", stamp, base+200)

	e.exec("UPDATE links SET flags = ? WHERE id = ?", productIsPhysical, product)
	e.expectFiles(r, base+104, base+100, base+102, base+101, base+103)

	e.exec("UPDATE links SET flags = 0 WHERE id = ?", product)
	e.exec("UPDATE base_variants SET deleted_at = ? WHERE id = ?", stamp, base+11)
	e.expectFiles(r, base+104, base+100, base+102, base+101, base+103)

	// With no alive variants the product provides even when its pages only embed: an embed
	// with an empty content array is no editor content.
	e.content(base+201, "Link", product, fmt.Sprintf(`[{"type":"fileEmbed","attrs":{"id":%q},"content":[]}]`, e.ids.Encrypt(base+101)))
	e.expectFiles(r, base+101)
}

func TestRecoverableHiddenContentPrefersTheCheapestVariantWithPages(t *testing.T) {
	e := newEnv(t)
	product, purchase := variantProduct(e, productHasSameRichContentForAllVariants)
	r := &Redirect{PurchaseID: ptr(purchase)}
	e.content(base+200, "Link", product, blankPage)
	e.content(base+201, "BaseVariant", base+11, textPage)
	// Variant 10 is cheaper but blank.
	e.expectFiles(r, base+102, base+101)

	e.content(base+202, "BaseVariant", base+10, textPage)
	e.expectFiles(r, base+103)
}

func TestADeletedPurchasedVariantDefersToTheProduct(t *testing.T) {
	e := newEnv(t)
	product, purchase := variantProduct(e, 0)
	e.variant(base+12, base+5, map[string]any{"price_difference_cents": 500, "deleted_at": stamp})
	e.file(base+104, map[string]any{"link_id": product})
	e.attach(base+12, base+104)
	e.buys(purchase, base+12)
	r := &Redirect{PurchaseID: ptr(purchase)}
	// Variant 11 (100) is the closest-priced alive variant.
	e.expectFiles(r, base+102, base+101)

	// An alive purchased variant sorts ahead of the deleted one.
	e.buys(purchase, base+10)
	e.expectFiles(r, base+103)

	// Orphaned, the deleted variant is its own provider.
	e.exec("DELETE FROM base_variants_purchases WHERE purchase_id = ? AND base_variant_id = ?", purchase, base+10)
	e.exec("UPDATE base_variants SET variant_category_id = ? WHERE id = ?", base+9, base+12)
	e.expectFiles(r, base+104)
}

func TestADeletedPurchasedVariantGetsTheClosestPricedAliveVariant(t *testing.T) {
	e := newEnv(t)
	product, purchase := variantProduct(e, 0)
	e.exec("UPDATE base_variants SET price_difference_cents = 10 WHERE id = ?", base+10)
	e.exec("UPDATE base_variants SET price_difference_cents = 90 WHERE id = ?", base+11)
	e.variant(base+12, base+5, map[string]any{"price_difference_cents": 70, "deleted_at": stamp})
	e.variant(base+13, base+5, map[string]any{"price_difference_cents": 50})
	e.file(base+104, map[string]any{"link_id": product})
	e.attach(base+12, base+104)
	e.attach(base+13, base+104)
	e.buys(purchase, base+12)
	r := &Redirect{PurchaseID: ptr(purchase)}
	// 90 and 50 are both 20 from the deleted 70: the cheaper wins, not the cheapest (10).
	e.expectFiles(r, base+104)

	// NULL prices count as 0, so 10 is closer to the deleted 100 than the NULL rows the sort puts first.
	e.exec("UPDATE base_variants SET price_difference_cents = NULL WHERE id IN (?, ?)", base+11, base+13)
	e.exec("UPDATE base_variants SET price_difference_cents = 100 WHERE id = ?", base+12)
	e.expectFiles(r, base+103)
}

func TestClosestPricedBreaksAnExactPriceTieByID(t *testing.T) {
	got := closestPriced([]*variant{{id: 13, priceDifferenceCents: 50}, {id: 11, priceDifferenceCents: 50}}, 70)
	if got == nil || got.id != 11 {
		t.Fatalf("closestPriced = %+v, want id 11", got)
	}
}

func TestASkuIsItsOwnProviderOnlyNextToAVariant(t *testing.T) {
	e := newEnv(t)
	product, purchase := variantProduct(e, 0)
	e.variant(base+12, 0, map[string]any{"type": "Sku", "variant_category_id": nil, "link_id": product})
	e.file(base+104, map[string]any{"link_id": product})
	e.attach(base+12, base+104)
	e.buys(purchase, base+12)
	r := &Redirect{PurchaseID: ptr(purchase)}
	// A SKU alone is no purchased Variant: the product picks its cheapest variant.
	e.expectFiles(r, base+103)

	// Next to a deleted Variant the alive SKU sorts first and provides.
	e.variant(base+13, base+5, map[string]any{"deleted_at": stamp})
	e.buys(purchase, base+13)
	e.expectFiles(r, base+104)
}

func TestRowsRailsWouldRaiseOnAreErrors(t *testing.T) {
	e := newEnv(t)
	_, purchase := variantProduct(e, 0)
	r := &Redirect{PurchaseID: ptr(purchase)}

	// A type no subclass has fails to instantiate.
	e.variant(base+12, base+5, map[string]any{"type": "Tier"})
	e.buys(purchase, base+12)
	e.expectError(r, `type "Tier"`)
	e.exec("DELETE FROM base_variants_purchases WHERE purchase_id = ?", purchase)

	// A blank type is a plain BaseVariant, which has no #link once it provides.
	e.exec("UPDATE base_variants SET type = NULL WHERE id = ?", base+12)
	e.variant(base+13, base+5, map[string]any{"deleted_at": stamp})
	e.buys(purchase, base+12, base+13)
	e.expectError(r, "has no #link")
	e.exec("DELETE FROM base_variants_purchases WHERE purchase_id = ?", purchase)

	// Variant's type = 'Variant' matches 'variant' under the collation, and the row then fails
	// to constantize wherever it is instantiated: among the siblings of a purchased variant
	// without files of its own...
	e.exec("UPDATE base_variants SET type = 'variant', price_difference_cents = 1000 WHERE id = ?", base+12)
	e.buys(purchase, base+13)
	e.expectError(r, `type "variant"`)
	e.exec("DELETE FROM base_variants_purchases WHERE purchase_id = ?", purchase)
	e.expectFiles(r, base+103)
	// ...and as the cheapest variant, where a NULL price sorts it.
	e.exec("UPDATE base_variants SET price_difference_cents = NULL WHERE id = ?", base+12)
	e.expectError(r, `type "variant"`)
	e.exec("UPDATE base_variants SET price_difference_cents = 1000 WHERE id = ?", base+12)

	// A page Ruby can't call #any? on is only an error where has_editor_content? reads it.
	e.exec("UPDATE base_variants SET deleted_at = ? WHERE id = ?", stamp, base+12)
	e.content(base+200, "BaseVariant", base+10, `"a string page"`)
	e.expectFiles(r, base+103)
	e.exec("UPDATE links SET flags = ? WHERE id = ?", productHasSameRichContentForAllVariants, base+1)
	e.expectError(r, "has no #any?")
}

func TestPurchasedVariantFilesWithoutAProvider(t *testing.T) {
	e := newEnv(t)
	product, purchase := variantProduct(e, 0)
	e.variant(base+12, 0, map[string]any{"type": "Sku", "variant_category_id": nil, "link_id": product})
	e.file(base+104, map[string]any{"link_id": product, "position": nil})
	e.file(base+105, map[string]any{"link_id": product, "deleted_at": stamp})
	e.attach(base+12, base+101, base+104, base+105)
	e.buys(purchase, base+11, base+12)
	l := newLoader(context.Background(), e.db, &Redirect{PurchaseID: ptr(purchase)}, e.ids)
	if _, err := l.loadPurchase(); err != nil {
		t.Fatal(err)
	}
	files, err := l.purchasedVariantFiles()
	if err != nil {
		t.Fatal(err)
	}
	var got []int64
	for _, f := range files {
		got = append(got, f.ID)
	}
	// Every purchased variant's alive files, once each, by position.
	if want := []int64{base + 104, base + 102, base + 101}; !slices.Equal(got, want) {
		t.Fatalf("got %v, want %v", offsets(got), offsets(want))
	}
}
