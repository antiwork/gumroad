package products

import (
	"encoding/json"
	"math/big"
	"strconv"
	"strings"

	"github.com/antiwork/gumroad/go_web/internal/db"
	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/railscache"
)

// catalogSearches is cached_sections' fetch, or cached_default_products_section's: Rails' entry,
// or the searches and the entry Rails would write for them, so both serve one cached order.
func (h *handler) catalogSearches(p *page, sections []*productsSection) ([]*catalogSearch, error) {
	productsKey, err := h.productsCacheKey(p)
	if err != nil {
		return nil, err
	}
	key := "profile-sections_default_" + h.railsRevision() + "-" + productsKey
	if sections[0] != nil {
		key = h.sectionsCacheKey(productsKey, profileSectionsCacheKey(p.seller.id, sections))
	}
	cached, found, err := h.readCache(p.Ctx, key)
	if err != nil {
		return nil, err
	}
	if !found {
		searches, err := h.searchSections(p, sections, catalogQuery{})
		if err != nil {
			return nil, err
		}
		p.cacheWrites = append(p.cacheWrites, pendingWrite{key, h.railsSectionsEntry(sections, searches), catalogTTL})
		return searches, nil
	}
	entries, ok := cached.([]any)
	if sections[0] == nil {
		entries, ok = []any{cached}, true
	}
	// Rails renders the entry's sections in its own order, so they must be this page's.
	if !ok || len(entries) != len(sections) {
		return nil, fallback("cached sections")
	}
	searches := make([]*catalogSearch, len(sections))
	for i, s := range sections {
		c, ok := readCachedSection(entries[i])
		if !ok || !c.matches(s, h) {
			return nil, fallback("cached sections")
		}
		searches[i] = c.search
	}
	return searches, nil
}

// railsSectionsEntry is the value cached_sections, or cached_default_products_section for the
// virtual section, caches: Ruby's types, as Marshal keeps them.
func (h *handler) railsSectionsEntry(sections []*productsSection, searches []*catalogSearch) any {
	entries := make([]any, len(sections))
	for i, s := range sections {
		entries[i] = h.railsProductsEntry(s, searches[i])
	}
	if sections[0] == nil {
		return entries[0]
	}
	return entries
}

// railsProductsEntry is a products section's entry, or the virtual section's for nil.
func (h *handler) railsProductsEntry(s *productsSection, search *catalogSearch) railscache.Hash {
	// ObfuscateIds' Base64 is US-ASCII.
	var id, header any = defaultProductsSectionID, nil
	showFilters, sort := false, pageLayoutSort
	if s != nil {
		id, header, showFilters, sort = railscache.ASCII(h.c.IDs.Encrypt(s.id)), s.header, s.showFilters, s.sort
	}
	ids := make([]any, len(search.IDs))
	for j, id := range search.IDs {
		ids[j] = strconv.FormatInt(id, 10)
	}
	return append(railsSectionHead(id, header, profileProductsSectionType),
		railscache.Pair{Key: railscache.Symbol("show_filters"), Value: showFilters},
		railscache.Pair{Key: railscache.Symbol("default_product_sort"), Value: sort},
		railscache.Pair{Key: railscache.Symbol("search_results"), Value: railscache.Hash{
			{Key: railscache.Symbol("total"), Value: search.Total},
			{Key: railscache.Symbol("tags_data"), Value: railsBuckets(search.Tags)},
			{Key: railscache.Symbol("filetypes_data"), Value: railsBuckets(search.Filetypes)},
			{Key: railscache.Symbol("taxonomy_attributes_data"), Value: []any{}},
			{Key: railscache.Symbol("products"), Value: ids},
		}})
}

// railsSectionHead is the id, header and type every entry starts with.
func railsSectionHead(id, header any, typ string) railscache.Hash {
	return railscache.Hash{{Key: railscache.Symbol("id"), Value: id}, {Key: railscache.Symbol("header"), Value: header},
		{Key: railscache.Symbol("type"), Value: typ}}
}

// productSectionSearches is cached_sections for the product's own sections: Rails' entry, or the
// search of every products section and the entry Rails would write for them, so both serve one
// cached order. It returns the listed sections' searches.
func (h *handler) productSectionSearches(p *page, ps *productSections) ([]*catalogSearch, error) {
	productsKey, err := h.productsCacheKey(p)
	if err != nil {
		return nil, err
	}
	times := make([]db.NullTime, len(ps.rows))
	for i, r := range ps.rows {
		times[i] = r.row.updatedAt
	}
	key := h.sectionsCacheKey(productsKey, productSectionsCacheKey(ps.productID, int64(len(ps.rows)), latestUpdatedAt(times...)))
	cached, found, err := h.readCache(p.Ctx, key)
	if err != nil {
		return nil, err
	}
	listed := map[string]*productsSection{}
	for _, s := range ps.products {
		listed[h.c.IDs.Encrypt(s.id)] = s
	}
	bySection := map[*productsSection]*catalogSearch{}
	// section_props finds every products entry's products, an unlisted one's too.
	var unlisted []int64
	if found {
		entries, ok := cached.([]any)
		if !ok || len(entries) != len(ps.rows) {
			return nil, fallback("cached sections")
		}
		for _, e := range entries {
			hash, _ := e.(railscache.Hash)
			if typ, _ := rubyString(hashValue(hash, railscache.Symbol("type"))); typ != profileProductsSectionType {
				continue
			}
			c, ok := readCachedSection(e)
			if !ok {
				return nil, fallback("cached sections")
			}
			s := listed[c.id]
			if s == nil {
				unlisted = append(unlisted, c.search.IDs...)
				continue
			}
			if !c.matches(s, h) {
				return nil, fallback("cached sections")
			}
			bySection[s] = c.search
		}
	} else {
		for _, r := range ps.rows {
			if r.productsErr != nil {
				return nil, r.productsErr
			}
		}
		searches, err := h.searchSections(p, ps.allProducts, catalogQuery{})
		if err != nil {
			return nil, err
		}
		for i, s := range ps.allProducts {
			bySection[s] = searches[i]
			if listed[h.c.IDs.Encrypt(s.id)] == nil {
				unlisted = append(unlisted, searches[i].IDs...)
			}
		}
		entry, err := h.productSectionsEntry(ps, bySection)
		if err != nil {
			return nil, err
		}
		p.cacheWrites = append(p.cacheWrites, pendingWrite{key, entry, catalogTTL})
	}
	searches := make([]*catalogSearch, len(ps.products))
	for i, s := range ps.products {
		if searches[i] = bySection[s]; searches[i] == nil {
			return nil, fallback("cached sections")
		}
	}
	return searches, h.productsExist(p, unlisted)
}

// productsExist is Link.find over the ids, which raises when a row is gone.
func (h *handler) productsExist(p *page, ids []int64) error {
	distinct := map[int64]bool{}
	for _, id := range ids {
		distinct[id] = true
	}
	if len(distinct) == 0 {
		return nil
	}
	args := make([]any, 0, len(distinct))
	for id := range distinct {
		args = append(args, id)
	}
	var n int
	if err := h.c.DB.QueryRowContext(p.Ctx, "SELECT COUNT(*) FROM links WHERE links.id IN ("+placeholders(len(args))+")", args...).Scan(&n); err != nil {
		return err
	}
	if n != len(distinct) {
		return fallback("catalog product missing")
	}
	return nil
}

// productSectionsEntry is cached_sections' value for the product's sections, each with the
// fields its type merges in.
func (h *handler) productSectionsEntry(ps *productSections, searches map[*productsSection]*catalogSearch) ([]any, error) {
	entries := make([]any, len(ps.rows))
	for i, r := range ps.rows {
		if r.products != nil {
			entries[i] = h.railsProductsEntry(r.products, searches[r.products])
			continue
		}
		e := railsSectionHead(railscache.ASCII(h.c.IDs.Encrypt(r.row.id)), r.row.shownHeader(), r.row.typ)
		var value any
		ok := true
		switch r.row.typ {
		case profileFeaturedSectionType:
			if len(r.ids) > 0 {
				e = append(e, railscache.Pair{Key: railscache.Symbol("featured_product_id"), Value: railscache.ASCII(h.c.IDs.Encrypt(r.ids[0]))})
			}
		case profileRichTextSectionType:
			value, ok = marshalJSON(r.data.get("text"))
			e = append(e, railscache.Pair{Key: railscache.Symbol("text"), Value: value})
		case profileSubscribeSectionType:
			value, ok = marshalJSON(r.data.get("button_label"))
			e = append(e, railscache.Pair{Key: railscache.Symbol("button_label"), Value: value})
		case profileWishlistsSectionType:
			shown := make([]any, len(r.ids))
			for j, id := range r.ids {
				shown[j] = railscache.ASCII(h.c.IDs.Encrypt(id))
			}
			e = append(e, railscache.Pair{Key: railscache.Symbol("shown_wishlists"), Value: shown})
		}
		if !ok {
			return nil, fallback("product section json_data")
		}
		entries[i] = e
	}
	return entries, nil
}

// marshalJSON is a value the JSON coder loaded as Ruby holds it: UTF-8 Strings, an Integer past
// int64 as a *big.Int, and Floats. MySQL's JSON type rejects a Float that would overflow.
func marshalJSON(v any) (any, bool) {
	switch v := v.(type) {
	case nil, bool, string:
		return v, true
	case json.Number:
		text := string(v)
		if !strings.ContainsAny(text, ".eE") {
			if n, err := strconv.ParseInt(text, 10, 64); err == nil {
				return n, true
			}
			return new(big.Int).SetString(text, 10)
		}
		f, err := strconv.ParseFloat(text, 64)
		return f, err == nil
	case []any:
		out := make([]any, len(v))
		for i, item := range v {
			var ok bool
			if out[i], ok = marshalJSON(item); !ok {
				return nil, false
			}
		}
		return out, true
	case *rails.Hash:
		out := make(railscache.Hash, 0, v.Len())
		for _, key := range v.Keys() {
			value, ok := marshalJSON(v.Value(key))
			if !ok {
				return nil, false
			}
			out = append(out, railscache.Pair{Key: key, Value: value})
		}
		return out, true
	}
	return nil, false
}

func railsBuckets(buckets []catalogBucket) []any {
	out := make([]any, len(buckets))
	for i, b := range buckets {
		out[i] = railscache.Hash{{Key: "key", Value: b.Key}, {Key: "doc_count", Value: b.DocCount}}
	}
	return out
}

// sectionsCacheKey is cached_sections' key for a relation's cache_key_with_version.
func (h *handler) sectionsCacheKey(productsKey, relation string) string {
	return "profile-sections_" + h.railsRevision() + "-" + productsKey + "-" + relation
}

// profileSectionsCacheKey is seller_profile_products_sections.on_profile's
// cache_key_with_version over its loaded rows.
func profileSectionsCacheKey(sellerID int64, sections []*productsSection) string {
	sql := "SELECT `seller_profile_sections`.* FROM `seller_profile_sections` WHERE `seller_profile_sections`.`type` = '" +
		profileProductsSectionType + "' AND `seller_profile_sections`.`seller_id` = " + strconv.FormatInt(sellerID, 10) +
		" AND `seller_profile_sections`.`product_id` IS NULL"
	times := make([]db.NullTime, len(sections))
	for i, s := range sections {
		times[i] = s.updatedAt
	}
	return relationCacheKey("seller_profile_products_sections", sql, int64(len(sections)), latestUpdatedAt(times...))
}

// productSectionsCacheKey is product.seller_profile_sections' cache_key_with_version.
func productSectionsCacheKey(productID, rows int64, latest db.NullTime) string {
	sql := "SELECT `seller_profile_sections`.* FROM `seller_profile_sections` WHERE `seller_profile_sections`.`product_id` = " +
		strconv.FormatInt(productID, 10)
	return relationCacheKey("seller_profile_sections", sql, rows, latest)
}

// latestUpdatedAt is the rows' maximum(:updated_at).
func latestUpdatedAt(times ...db.NullTime) db.NullTime {
	var latest db.NullTime
	for _, t := range times {
		if t.Valid && (!latest.Valid || t.Time.After(latest.Time)) {
			latest = t
		}
	}
	return latest
}

type cachedSection struct {
	id, sort    string
	header      any
	showFilters bool
	search      *catalogSearch
}

// matches is whether the entry renders as the section s does; the virtual section's fields
// are constants.
func (c *cachedSection) matches(s *productsSection, h *handler) bool {
	if s == nil {
		return c.id == defaultProductsSectionID
	}
	return c.id == h.c.IDs.Encrypt(s.id) && c.header == s.header && c.showFilters == s.showFilters && c.sort == s.sort
}

func readCachedSection(entry any) (*cachedSection, bool) {
	section, ok := entry.(railscache.Hash)
	if !ok {
		return nil, false
	}
	c := &cachedSection{}
	var idOK, sortOK, headerOK bool
	c.id, idOK = rubyString(hashValue(section, railscache.Symbol("id")))
	c.sort, sortOK = rubyString(hashValue(section, railscache.Symbol("default_product_sort")))
	c.showFilters, _ = hashValue(section, railscache.Symbol("show_filters")).(bool)
	if header := hashValue(section, railscache.Symbol("header")); header == nil {
		headerOK = true
	} else {
		c.header, headerOK = rubyString(header)
	}
	results, resultsOK := hashValue(section, railscache.Symbol("search_results")).(railscache.Hash)
	if !idOK || !sortOK || !headerOK || !resultsOK {
		return nil, false
	}
	total, totalOK := hashValue(results, railscache.Symbol("total")).(int64)
	ids, idsOK := hashValue(results, railscache.Symbol("products")).([]any)
	tags, tagsOK := cachedBuckets(hashValue(results, railscache.Symbol("tags_data")))
	filetypes, filetypesOK := cachedBuckets(hashValue(results, railscache.Symbol("filetypes_data")))
	if !totalOK || !idsOK || !tagsOK || !filetypesOK {
		return nil, false
	}
	c.search = &catalogSearch{Total: total, Tags: tags, Filetypes: filetypes, IDs: make([]int64, 0, len(ids))}
	for _, v := range ids {
		text, _ := rubyString(v)
		n, ok := decimalID(text)
		if !ok {
			return nil, false
		}
		c.search.IDs = append(c.search.IDs, n)
	}
	return c, true
}

// cachedBuckets reads an aggregation's buckets, each a Hash of "key" and "doc_count".
func cachedBuckets(v any) ([]catalogBucket, bool) {
	list, ok := v.([]any)
	if !ok {
		return nil, false
	}
	out := make([]catalogBucket, 0, len(list))
	for _, b := range list {
		h, ok := b.(railscache.Hash)
		if !ok || len(h) != 2 {
			return nil, false
		}
		key, keyOK := rubyString(hashValue(h, "key"))
		count, countOK := hashValue(h, "doc_count").(int64)
		if !keyOK || !countOK {
			return nil, false
		}
		out = append(out, catalogBucket{Key: key, DocCount: count})
	}
	return out, true
}

// hashValue is h[key], with a String key matched whatever its encoding.
func hashValue(h railscache.Hash, key any) any {
	for _, pair := range h {
		if pair.Key == key {
			return pair.Value
		}
		if _, sym := key.(railscache.Symbol); !sym {
			if k, ok := rubyString(pair.Key); ok && k == key {
				return pair.Value
			}
		}
	}
	return nil
}

// rubyString is a String of any encoding the cache holds.
func rubyString(v any) (string, bool) {
	switch v := v.(type) {
	case string:
		return v, true
	case railscache.ASCII:
		return string(v), true
	case railscache.Binary:
		return string(v), true
	}
	return "", false
}

// railsRevision is the REVISION Rails.cache is namespaced under, which ProfileSectionsPresenter's
// keys embed.
func (h *handler) railsRevision() string {
	if h.c.Page.Revision != nil {
		return h.c.Page.Revision()
	}
	return h.c.Env.Revision
}
