package products

import (
	"strconv"

	"github.com/antiwork/gumroad/go_web/internal/db"
	"github.com/antiwork/gumroad/go_web/internal/railscache"
)

// railsCatalogSearches is the searches in Rails' cached_sections entry for the seller's profile
// products sections, or cached_default_products_section's: serving the order Rails cached
// rather than a fresher search. nil on a miss.
func (h *handler) railsCatalogSearches(p *page, sections []*productsSection) ([]*catalogSearch, error) {
	productsKey, err := h.productsCacheKey(p)
	if err != nil {
		return nil, err
	}
	rev := h.c.Env.Revision
	key := "profile-sections_default_" + rev + "-" + productsKey
	if sections[0] != nil {
		key = "profile-sections_" + rev + "-" + productsKey + "-" + profileSectionsCacheKey(p.seller.id, sections)
	}
	cached, found, err := h.readCache(p.Ctx, key)
	if err != nil || !found {
		return nil, err
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

// profileSectionsCacheKey is seller_profile_products_sections.on_profile's
// cache_key_with_version over its loaded rows.
func profileSectionsCacheKey(sellerID int64, sections []*productsSection) string {
	sql := "SELECT `seller_profile_sections`.* FROM `seller_profile_sections` WHERE `seller_profile_sections`.`type` = '" +
		profileProductsSectionType + "' AND `seller_profile_sections`.`seller_id` = " + strconv.FormatInt(sellerID, 10) +
		" AND `seller_profile_sections`.`product_id` IS NULL"
	var latest db.NullTime
	for _, s := range sections {
		if s.updatedAt.Valid && (!latest.Valid || s.updatedAt.Time.After(latest.Time)) {
			latest = s.updatedAt
		}
	}
	return relationCacheKey("seller_profile_products_sections", sql, int64(len(sections)), latest)
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
		text, ok := rubyString(v)
		n, err := strconv.ParseInt(text, 10, 64)
		if !ok || err != nil || strconv.FormatInt(n, 10) != text {
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
