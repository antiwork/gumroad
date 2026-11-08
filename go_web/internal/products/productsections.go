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
	// rows and allProducts are every one of the product's sections, listed or not, which
	// cached_sections caches under a key of productID's.
	productID   int64
	rows        []cachedRow
	allProducts []*productsSection
}

// cachedRow is a section as cached_sections reads it.
type cachedRow struct {
	row      sectionRow
	data     jsonData
	products *productsSection
	// productsErr is an unlisted products section's, which only a search on a miss raises on.
	productsErr error
	// ids are a featured section's product or a wishlists section's wishlists.
	ids []int64
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
	// editor is what the seller's own view merges into a products section's props.
	editor *rails.RHash
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
	ps := &productSections{productID: prod.id}
	editing := p.ownView()
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
		cached := cachedRow{row: r, data: j}
		if r.typ == profileProductsSectionType {
			switch products, err := r.productsSectionFrom(j); {
			case err != nil && listed:
				return nil, err
			case err != nil:
				cached.productsErr = err
			default:
				cached.products = products
				ps.allProducts = append(ps.allProducts, products)
			}
		}
		ps.rows = append(ps.rows, cached)
		row := &ps.rows[len(ps.rows)-1]
		var head *rails.RHash
		if listed {
			header := r.shownHeader()
			if editing {
				// section.header || ""
				header = r.header.String
			}
			head = sectionHead(h.c.IDs.Encrypt(r.id), header, r.typ)
			byKey[key] = listedSection{props: head}
		}
		// The editor's hide_header follows the cached keys and precedes those section_props adds.
		hideHeader := func() {
			if editing && head != nil {
				head.Sym("hide_header", r.hidesHeader())
			}
		}
		if r.typ == profileFeaturedSectionType {
			ids, err := featuredProductID(j)
			if err != nil {
				return nil, err
			}
			row.ids = ids
			if editing {
				// The editor's shape names the product without rendering it.
				if head != nil && len(ids) > 0 {
					head.Sym("featured_product_id", h.c.IDs.Encrypt(ids[0]))
				}
				hideHeader()
				continue
			}
			// Rails builds an unlisted one's product_props too, so it is loaded and dropped.
			featured = append(featured, pending{head, ids})
			continue
		}
		if r.typ == profileWishlistsSectionType {
			// An unlisted one's cards are built and dropped too.
			ids, err := shownWishlists(j)
			if err != nil {
				return nil, err
			}
			row.ids = ids
			if listed {
				head.Sym("shown_wishlists", h.encryptIDs(ids))
			}
			hideHeader()
			wishlists = append(wishlists, pending{head, ids})
			continue
		}
		if !listed {
			continue
		}
		switch r.typ {
		case profileProductsSectionType:
			ps.products = append(ps.products, row.products)
			listing := listedSection{products: row.products}
			if editing {
				listing.editor = rails.NewRHash().Sym("header", r.header.String).Sym("hide_header", r.hidesHeader()).
					Sym("shown_products", h.encryptIDs(row.products.shownProducts)).Sym("add_new_products", j.get("add_new_products"))
			}
			byKey[key] = listing
		case profileSubscribeSectionType:
			head.Sym("button_label", j.get("button_label"))
			hideHeader()
		case profileRichTextSectionType:
			head.Sym("text", j.get("text"))
			hideHeader()
		case profilePostsSectionType:
			// section.shown_posts: nil matches no post, as where(id: nil) does.
			var shown []int64
			if raw := j.get("shown_posts"); raw != nil {
				list, _ := raw.([]any)
				if shown, ok = jsonIDs(list); !ok || list == nil {
					return nil, fallback("product section json_data")
				}
			}
			hideHeader()
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
		if !editing {
			s.props.Sym("posts", list)
			continue
		}
		ids := make([]any, len(list))
		for i, post := range list {
			ids[i] = post.(*rails.RHash).Get("id")
		}
		s.props.Sym("shown_posts", ids)
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
	if len(ps.products) > 0 && h.c.Page.Search == nil {
		return nil, fallback("products section search")
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
		searches, err := h.productSectionSearches(p, ps)
		if err != nil {
			return nil, err
		}
		// section_props searches afresh with any visitor search param, after the cached fetch.
		if p.visitorSearch {
			if searches, err = h.visitorSearchSections(p, ps.products); err != nil {
				return nil, err
			}
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
		switch {
		case s.props != nil:
			out[i] = s.props
		case s.editor != nil:
			out[i] = built[s.products].(*rails.RHash).Merge(s.editor)
		default:
			out[i] = built[s.products]
		}
	}
	return out, nil
}

// visiblePosts is ProfileSectionsPresenter#visible_posts for a section: the seller's shown
// posts that are published on the profile, newest first.
func (h *handler) visiblePosts(p *page, shown []int64) ([]any, error) {
	if len(shown) == 0 {
		return []any{}, nil
	}
	return h.profilePosts(p, " AND installments.id IN ("+placeholders(len(shown))+")", int64Args(shown)...)
}

// profilePosts is visible_posts, narrowed by filter.
func (h *handler) profilePosts(p *page, filter string, args ...any) ([]any, error) {
	rows, err := h.c.DB.QueryContext(p.Ctx, "SELECT installments.id, installments.name, installments.slug, installments.published_at"+
		" FROM installments WHERE installments.seller_id = ? AND installments.deleted_at IS NULL AND installments.published_at IS NOT NULL"+
		" AND installments.installment_type = 'audience' AND (installments.flags & ?) != 0 AND installments.workflow_id IS NULL"+
		filter+" ORDER BY installments.published_at DESC, installments.id ASC LIMIT 999",
		append([]any{p.seller.id, installmentShownOnProfile}, args...)...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []any{}
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

// encryptIDs is ids.map { ObfuscateIds.encrypt(_1) }.
func (h *handler) encryptIDs(ids []int64) []any {
	out := make([]any, len(ids))
	for i, id := range ids {
		out[i] = h.c.IDs.Encrypt(id)
	}
	return out
}

// editorProps is the editing payload's products, posts and wishlist_options.
func (h *handler) editorProps(p *page) (*rails.RHash, error) {
	products := []any{}
	// Rails' own statement, which sets no order.
	err := scanNamed(p.Ctx, h.c.DB, func(cols map[string]any) func() {
		var id int64
		var name sql.NullString
		cols["id"], cols["name"] = &id, &name
		return func() {
			products = append(products, rails.NewRHash().Sym("id", h.c.IDs.Encrypt(id)).Sym("name", nullString(name)))
		}
	}, "SELECT `links`.`id`, `links`.`name` FROM `links` WHERE `links`.`user_id` = ? AND `links`.`purchase_disabled_at` IS NULL"+
		" AND `links`.`banned_at` IS NULL AND `links`.`deleted_at` IS NULL AND ((`links`.`flags` & ? = 0))", p.seller.id, productArchived)
	if err != nil {
		return nil, err
	}
	posts, err := h.profilePosts(p, "")
	if err != nil {
		return nil, err
	}
	// seller.wishlists.alive: the editor's current seller is the product's.
	options := make([]any, len(p.currentSeller.wishlists))
	for i, w := range p.currentSeller.wishlists {
		options[i] = rails.NewRHash().Sym("id", h.c.IDs.Encrypt(w.id)).Sym("name", nullString(w.name))
	}
	return rails.NewRHash().Sym("products", products).Sym("posts", posts).Sym("wishlist_options", options), nil
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
	// product_props renders it for the same visitor, whose collaboration on it lets them edit it.
	if err := h.viewerCollaborates(fp, featured); err != nil {
		return nil, err
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
		productsKey: p.productsKey, parent: parent, viewer: p.viewer, currentSeller: p.currentSeller, teamRole: p.teamRole,
		customDomain: p.customDomain, productDomain: p.productDomain}
}

// appendNew appends each of ids that s lacks.
func appendNew(s []int64, ids ...int64) []int64 {
	for _, id := range ids {
		if !slices.Contains(s, id) {
			s = append(s, id)
		}
	}
	return s
}

// absorb takes back what a featured page read or queued.
func (p *page) absorb(fp *page) {
	p.cacheWrites = append(p.cacheWrites, fp.cacheWrites...)
	fp.cacheWrites = nil
	p.warmReputation = p.warmReputation || fp.warmReputation
	p.retinaPushes = appendNew(p.retinaPushes, fp.retinaPushes...)
	p.posterPushes = appendNew(p.posterPushes, fp.posterPushes...)
	p.avatarPushes = appendNew(p.avatarPushes, fp.avatarPushes...)
	if p.settleable == nil {
		p.settleable = fp.settleable
	}
	if p.productsKey == "" {
		p.productsKey = fp.productsKey
	}
}
