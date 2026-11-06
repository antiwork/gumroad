package products

import (
	"encoding/json"
	"slices"
	"strconv"
	"strings"

	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// productSections are the product's own sections that Link#sections lists, in its order, each
// either rendered already or a products section still to search.
type productSections struct {
	listed   []listedSection
	products []*productsSection
}

type listedSection struct {
	props    *rails.RHash
	products *productsSection
}

// sectionTypes are SellerProfileSection's subclasses.
var sectionTypes = map[string]bool{
	profileProductsSectionType: true, profileSubscribeSectionType: true, profileRichTextSectionType: true,
	"SellerProfilePostsSection": true, "SellerProfileFeaturedProductSection": true, "SellerProfileWishlistsSection": true,
}

// listProductSections reads the sections product_page_props renders, before any search: Rails
// builds every one of the product's sections, so a row it would raise on goes to Rails even
// when the product doesn't list it.
func (h *handler) listProductSections(p *page, prod *product, v *view) (*productSections, error) {
	ps := &productSections{}
	raw, ok := v.productJSON.present("sections")
	if !ok {
		return ps, nil
	}
	var list []any
	switch raw := raw.(type) {
	case []any:
		list = raw
	case *rails.Hash:
		// filter_map over a Hash finds no section.
		return ps, nil
	default:
		return nil, fallback("product sections json_data")
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
		if !slices.Contains(keys, key) {
			continue
		}
		var field string
		switch r.typ {
		case profileProductsSectionType:
			s, err := r.productsSection()
			if err != nil {
				return nil, err
			}
			ps.products = append(ps.products, s)
			byKey[key] = listedSection{products: s}
			continue
		case profileSubscribeSectionType:
			field = "button_label"
		case profileRichTextSectionType:
			field = "text"
		default:
			return nil, fallback("product section " + r.typ)
		}
		byKey[key] = listedSection{props: sectionHead(h.c.IDs.Encrypt(r.id), r.shownHeader(), r.typ).Sym(field, j.get(field))}
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	for _, key := range keys {
		if s, ok := byKey[key]; ok {
			ps.listed = append(ps.listed, s)
		}
	}
	if len(ps.products) > 0 {
		switch {
		case h.c.Page.Search == nil:
			return nil, fallback("products section search")
		case p.hasAutoApplyCode:
			// Cards price through the seller's auto-applied code and label its sale.
			return nil, fallback("products section auto-apply")
		}
	}
	return ps, nil
}

// renderProductSections is the listed sections' props, searching the products sections without omit_product.
func (h *handler) renderProductSections(p *page, ps *productSections, buyer *string) ([]any, error) {
	built := map[*productsSection]any{}
	if len(ps.products) > 0 {
		props, err := h.productsSectionsProps(p, nil, ps.products, buyer)
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
