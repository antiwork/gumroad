package delivery

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"fmt"
	"sort"

	"github.com/antiwork/gumroad/go_web/internal/obfuscate"
	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// ErrUnported is a download page that reads what this port leaves to Rails.
var ErrUnported = errors.New("download page content this port leaves to Rails")

// rubySortStableUpTo is how many elements Array#sort_by orders like a stable sort on every
// platform: past it, tied keys fall where the C library's qsort_r puts them.
const rubySortStableUpTo = 6

// displayColumns is download_attributes' select list, all of product_files.
const displayColumns = "SELECT `product_files`.* FROM `product_files`"

// Page is a url redirect as the download page reads it, each row once, as the memoized
// associations on Rails' UrlRedirect are.
type Page struct {
	l     *loader
	files []ProductFile
	read  bool
}

func NewPage(ctx context.Context, db *sql.DB, r *Redirect, ids *obfuscate.IDs) *Page {
	l := newLoader(ctx, db, r, ids)
	l.display = true
	return &Page{l: l}
}

// Owner is with_product_files and referenced_link as the page's title, favicon and
// variant_id read them.
type Owner struct {
	// VariantID is with_product_files' id when it is a BaseVariant.
	VariantID *int64
	// Name is with_product_files.name, ReferencedName referenced_link.name.
	Name, ReferencedName sql.NullString
	// ReferencedProductID is referenced_link's id, and SellerID with_product_files.user's.
	ReferencedProductID, SellerID *int64
}

// Owner loads Owner. A redirect without files to own, or one a post owns, is left to Rails,
// where the page raises or reads the post.
func (p *Page) Owner() (*Owner, error) {
	l := p.l
	entity, err := l.withProductFiles()
	if err != nil {
		return nil, err
	}
	if entity == nil || entity.installment {
		return nil, ErrUnported
	}
	o := &Owner{}
	referenced, err := l.loadReferencedProduct()
	if err != nil {
		return nil, err
	}
	var referencedUser sql.NullInt64
	if referenced != nil {
		o.ReferencedProductID = &referenced.id
		if _, err := l.queryRow("SELECT `links`.`name`, `links`.`user_id` FROM `links` WHERE `links`.`id` = ? LIMIT 1",
			[]any{referenced.id}, &o.ReferencedName, &referencedUser); err != nil {
			return nil, err
		}
	}
	userID := referencedUser
	switch {
	case entity.product != nil:
		if referenced == nil || entity.product.id != referenced.id {
			return nil, ErrUnported
		}
		o.Name = o.ReferencedName
	case entity.variant != nil:
		o.VariantID = &entity.variant.id
		if _, err := l.queryRow("SELECT `base_variants`.`name` FROM `base_variants` WHERE `base_variants`.`id` = ? LIMIT 1",
			[]any{entity.variant.id}, &o.Name); err != nil {
			return nil, err
		}
		// BaseVariant#user is its link's.
		product, err := l.owningProduct(entity.variant)
		if err != nil {
			return nil, err
		}
		if product == nil {
			return nil, ErrUnported
		}
		if _, err := l.queryRow("SELECT `links`.`user_id` FROM `links` WHERE `links`.`id` = ? LIMIT 1", []any{product.id}, &userID); err != nil {
			return nil, err
		}
	default:
		return nil, ErrUnported
	}
	if userID.Valid {
		o.SellerID = &userID.Int64
	}
	return o, nil
}

// Files is alive_product_files as download_attributes reads them, read once.
func (p *Page) Files() ([]ProductFile, error) {
	if p.read {
		return p.files, nil
	}
	files, err := p.l.aliveProductFiles()
	if err != nil {
		return nil, err
	}
	if len(files) != len(p.l.displayed) {
		return nil, fmt.Errorf("delivery: %d files read for display, %d listed", len(p.l.displayed), len(files))
	}
	p.files, p.read = files, true
	return files, nil
}

// Streamable is whether any of the files is a video.
func (p *Page) Streamable() (bool, error) {
	files, err := p.Files()
	for _, f := range files {
		if f.streamable() {
			return true, err
		}
	}
	return false, err
}

// RichPages is what the download page reads from url_redirect.rich_content_json.
type RichPages struct {
	// JSON is rich_content_json.presence: nil, or the pages.
	JSON any
	// MayHavePosts is a page that could hold a posts node, which has_embedded_posts? reads.
	MayHavePosts bool
}

// RichContentPages is url_redirect.rich_content_json.presence without a completed
// commission's page. A variant's pages, a description has_posts? raises on, and tied
// positions only the C library can order are left to Rails.
func (p *Page) RichContentPages() (*RichPages, error) {
	l := p.l
	provider, err := l.richContentProvider()
	if err != nil {
		return nil, err
	}
	if provider == nil {
		return &RichPages{}, nil
	}
	if provider.variant != nil || provider.installment {
		return nil, ErrUnported
	}
	contents, err := l.contentsOf(provider)
	if err != nil {
		return nil, err
	}
	if len(contents) == 0 {
		return &RichPages{}, nil
	}
	pages := append([]*RichContent(nil), contents...)
	positions := map[int64]bool{}
	for _, c := range pages {
		if positions[c.position] && len(pages) > rubySortStableUpTo {
			return nil, ErrUnported
		}
		positions[c.position] = true
	}
	sort.SliceStable(pages, func(i, j int) bool { return pages[i].position < pages[j].position })

	out := &RichPages{}
	json := make([]any, len(pages))
	for i, c := range pages {
		description, err := rails.ParseJSON(c.DescriptionJSON)
		if _, isList := description.([]any); err != nil || !isList {
			// has_posts? calls description.any?, which only a list has here.
			return nil, ErrUnported
		}
		// has_posts? needs a node typed "posts", which needs the word.
		out.MayHavePosts = out.MayHavePosts || bytes.Contains(c.DescriptionJSON, []byte("posts"))
		external := l.ids.Encrypt(c.id)
		json[i] = rails.NewRHash().
			Sym("id", external).
			Sym("page_id", external).
			Sym("title", nullString(c.Title)).
			Sym("variant_id", nil).
			Sym("description", rails.NewRHash().Sym("type", "doc").Sym("content", description)).
			Sym("updated_at", c.updatedAt)
	}
	out.JSON = json
	return out, nil
}
