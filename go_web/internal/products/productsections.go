package products

import (
	"database/sql"
	"encoding/json"
	"errors"
	"slices"
	"strconv"
	"strings"

	"github.com/antiwork/gumroad/go_web/internal/db"
	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// installmentShownOnProfile is flag 8 of Installment's has_flags.
const installmentShownOnProfile = 1 << 7

// productSections are the product's own sections that Link#sections lists, in its order, each
// either rendered already or a products section still to search.
type productSections struct {
	listed   []listedSection
	products []*productsSection
	featured []*featuredSection
}

// featuredSection is a listed featured product section and its product, loaded short of its
// sales count, when it names one.
type featuredSection struct {
	props *rails.RHash
	page  *page
	prod  *product
	view  *view
}

type listedSection struct {
	props    *rails.RHash
	products *productsSection
}

// sectionTypes are SellerProfileSection's subclasses.
var sectionTypes = map[string]bool{
	profileProductsSectionType: true, profileSubscribeSectionType: true, profileRichTextSectionType: true,
	profilePostsSectionType: true, profileFeaturedSectionType: true, profileWishlistsSectionType: true,
}

// listProductSections reads the sections product_page_props renders, before any search: Rails
// builds every one of the product's sections, so a row it would raise on goes to Rails even
// when the product doesn't list it.
func (h *handler) listProductSections(p *page, prod *product, v *view) (*productSections, error) {
	ps := &productSections{}
	// Link#sections is [] when blank; filter_map finds nothing in a Hash and raises on the rest.
	var list []any
	if raw, ok := v.productJSON.present("sections"); ok {
		switch raw := raw.(type) {
		case []any:
			list = raw
		case *rails.Hash:
		default:
			return nil, fallback("product sections json_data")
		}
	}
	if !p.hasProductSections {
		return ps, nil
	}
	// Each entry matches by ObfuscateIds.encrypt(id), which encrypts id.to_s.
	keys := make([]string, len(list))
	for i, e := range list {
		switch e := e.(type) {
		case string:
			keys[i] = e
		case json.Number:
			if !strings.ContainsAny(string(e), ".eE") {
				keys[i] = string(e)
			}
		}
	}

	rows, err := h.c.DB.QueryContext(p.Ctx, "SELECT "+sectionColumns+" FROM seller_profile_sections"+
		" WHERE seller_profile_sections.product_id = ? ORDER BY seller_profile_sections.id", prod.id)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	byKey := map[string]listedSection{}
	type pending struct {
		props *rails.RHash
		ids   []int64
	}
	var posts, featured, wishlists []pending
	for rows.Next() {
		var r sectionRow
		if err := rows.Scan(r.dest()...); err != nil {
			return nil, err
		}
		j, ok := parseJSONData(r.data)
		if !sectionTypes[r.typ] || !ok || j.h == nil {
			// An unknown type raises SubclassNotFound, and a NULL json_data raises on its keys.
			return nil, fallback("product section row")
		}
		key := strconv.FormatInt(r.id, 10)
		listed := slices.Contains(keys, key)
		var head *rails.RHash
		if listed {
			head = sectionHead(h.c.IDs.Encrypt(r.id), r.shownHeader(), r.typ)
			byKey[key] = listedSection{props: head}
		}
		if r.typ == profileFeaturedSectionType {
			// Rails builds an unlisted one's product_props too, so it is loaded and dropped.
			ids, err := featuredProductID(j)
			if err != nil {
				return nil, err
			}
			featured = append(featured, pending{head, ids})
			continue
		}
		if r.typ == profileWishlistsSectionType {
			// An unlisted one's cards are built and dropped too.
			ids, err := shownWishlists(j)
			if err != nil {
				return nil, err
			}
			if listed {
				encrypted := make([]any, len(ids))
				for i, id := range ids {
					encrypted[i] = h.c.IDs.Encrypt(id)
				}
				head.Sym("shown_wishlists", encrypted)
			}
			wishlists = append(wishlists, pending{head, ids})
			continue
		}
		if !listed {
			continue
		}
		switch r.typ {
		case profileProductsSectionType:
			s, err := r.productsSection()
			if err != nil {
				return nil, err
			}
			ps.products = append(ps.products, s)
			byKey[key] = listedSection{products: s}
		case profileSubscribeSectionType:
			head.Sym("button_label", j.get("button_label"))
		case profileRichTextSectionType:
			head.Sym("text", j.get("text"))
		case profilePostsSectionType:
			// section.shown_posts: nil matches no post, as where(id: nil) does.
			var shown []int64
			if raw := j.get("shown_posts"); raw != nil {
				list, _ := raw.([]any)
				if shown, ok = jsonIDs(list); !ok || list == nil {
					return nil, fallback("product section json_data")
				}
			}
			posts = append(posts, pending{head, shown})
		default:
			return nil, fallback("product section " + r.typ)
		}
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	rows.Close()
	for _, s := range posts {
		list, err := h.visiblePosts(p, s.ids)
		if err != nil {
			return nil, err
		}
		s.props.Sym("posts", list)
	}
	for _, s := range wishlists {
		cards, err := h.wishlistCards(p, s.ids)
		if err != nil {
			return nil, err
		}
		if s.props != nil {
			s.props.Sym("wishlists", cards)
		}
	}
	for _, s := range featured {
		f, err := h.prepareFeatured(p, v, s.ids)
		if err != nil {
			return nil, err
		}
		if s.props == nil {
			continue
		}
		if f == nil {
			s.props.Sym("props", nil)
			continue
		}
		f.props = s.props
		ps.featured = append(ps.featured, f)
	}
	for _, key := range keys {
		if s, ok := byKey[key]; ok {
			ps.listed = append(ps.listed, s)
		}
	}
	if len(ps.products) > 0 {
		switch {
		case reviewSorted(ps.products) && !p.visitorSearch:
			return nil, fallback("products section review sort")
		case h.c.Page.Search == nil:
			return nil, fallback("products section search")
		}
	}
	return ps, nil
}

// featuredProductID is the featured_product_id the cached external id finds by: an Integer, or
// a decimal String, which to_s leaves the same.
func featuredProductID(j jsonData) ([]int64, error) {
	switch raw := j.get("featured_product_id").(type) {
	case nil:
		return nil, nil
	case json.Number, string:
		text, _ := rails.String(raw)
		if id, ok := decimalID(text); ok {
			return []int64{id}, nil
		}
	}
	return nil, fallback("product section json_data")
}

// renderProductSections is the listed sections' props: the featured products' sales counts and
// props, and the products sections searched without omit_product.
func (h *handler) renderProductSections(p *page, ps *productSections, buyer *string) ([]any, error) {
	for _, f := range ps.featured {
		if err := h.loadSalesCount(p.Ctx, f.page, f.prod, f.view); err != nil {
			return nil, err
		}
		p.absorb(f.page)
		props := rails.NewRHash()
		h.productProps(props, f.page, f.prod, f.view)
		f.props.Sym("props", props)
	}
	built := map[*productsSection]any{}
	if len(ps.products) > 0 {
		search := h.cachedCatalog
		if p.visitorSearch {
			// section_props replaces the search, so go_web's cache and its review-sort caveat
			// don't apply.
			search = h.searchSections
		}
		searches, err := search(p, ps.products)
		if err != nil {
			return nil, err
		}
		props, err := h.productsSectionsProps(p, nil, ps.products, searches, buyer)
		if err != nil {
			return nil, err
		}
		for i, s := range ps.products {
			built[s] = props[i]
		}
	}
	out := make([]any, len(ps.listed))
	for i, s := range ps.listed {
		if s.props != nil {
			out[i] = s.props
		} else {
			out[i] = built[s.products]
		}
	}
	return out, nil
}

// visiblePosts is ProfileSectionsPresenter#visible_posts for a section: the seller's shown
// posts that are published on the profile, newest first.
func (h *handler) visiblePosts(p *page, shown []int64) ([]any, error) {
	out := []any{}
	if len(shown) == 0 {
		return out, nil
	}
	rows, err := h.c.DB.QueryContext(p.Ctx, "SELECT installments.id, installments.name, installments.slug, installments.published_at"+
		" FROM installments WHERE installments.seller_id = ? AND installments.deleted_at IS NULL AND installments.published_at IS NOT NULL"+
		" AND installments.installment_type = 'audience' AND (installments.flags & ?) != 0 AND installments.workflow_id IS NULL"+
		" AND installments.id IN ("+placeholders(len(shown))+") ORDER BY installments.published_at DESC, installments.id ASC LIMIT 999",
		append([]any{p.seller.id, installmentShownOnProfile}, int64Args(shown)...)...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var id int64
		var name, slug sql.NullString
		var published db.NullTime
		if err := rows.Scan(&id, &name, &slug, &published); err != nil {
			return nil, err
		}
		out = append(out, rails.NewRHash().Sym("id", h.c.IDs.Encrypt(id)).Sym("name", nullString(name)).
			Sym("slug", nullString(slug)).Sym("published_at", published.OrNil()))
	}
	return out, rows.Err()
}

// prepareFeatured loads the seller's alive product a featured section names, as
// ProductPresenter#product_props would render it with no URL code, short of its sales count; nil
// when there is none.
func (h *handler) prepareFeatured(p *page, parent *view, ids []int64) (*featuredSection, error) {
	if len(ids) == 0 {
		return nil, nil
	}
	featured := &product{}
	err := h.c.DB.QueryRowContext(p.Ctx, "SELECT "+productColumns+" FROM links WHERE links.id = ? AND links.user_id = ? LIMIT 1",
		ids[0], p.seller.id).Scan(featured.dest()...)
	if errors.Is(err, sql.ErrNoRows) || err == nil && !featured.alive() {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	fp := p.featuredPage(parent)
	if reason, err := h.unportedShape(p.Ctx, fp, featured); err != nil || reason != "" {
		return nil, firstErr(err, fallback(reason))
	}
	// product_props renders it for the same visitor, whose purchase or collaboration changes it.
	if fp.viewer != nil {
		if err := h.viewerHasNoPart(fp, featured, fp.viewer.id); err != nil {
			return nil, err
		}
	}
	v, err := h.loadView(p.Ctx, fp, featured)
	if err != nil {
		return nil, err
	}
	p.absorb(fp)
	return &featuredSection{page: fp, prod: featured, view: v}, nil
}

// featuredPage is the page a featured product renders on, sharing this one's seller-level reads.
// Its gates and offer codes are its own: autoApply, for one, holds the product it was read for.
func (p *page) featuredPage(parent *view) *page {
	if p.rates == nil {
		p.rates = map[string]rateRead{}
	}
	if p.flags == nil {
		p.flags = map[string]bool{}
	}
	return &page{Visit: p.Visit, seller: p.seller, rates: p.rates, settleable: p.settleable, flags: p.flags,
		productsKey: p.productsKey, parent: parent, viewer: p.viewer}
}

// absorb takes back what a featured page read or queued.
func (p *page) absorb(fp *page) {
	p.cacheWrites = append(p.cacheWrites, fp.cacheWrites...)
	fp.cacheWrites = nil
	p.warmReputation = p.warmReputation || fp.warmReputation
	if p.settleable == nil {
		p.settleable = fp.settleable
	}
	if p.productsKey == "" {
		p.productsKey = fp.productsKey
	}
}
