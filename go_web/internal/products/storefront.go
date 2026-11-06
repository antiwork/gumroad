package products

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/db"
	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/web"
)

const (
	productComponent    = "Products/Show"
	storefrontComponent = "Products/Profile/Show"
	iframeComponent     = "Products/Iframe/Show"
	// ProfileSectionsPresenter::DEFAULT_PRODUCTS_SECTION_ID and _TYPE, and ProductSortKey::PAGE_LAYOUT.
	defaultProductsSectionID    = "default-products"
	profileProductsSectionType  = "SellerProfileProductsSection"
	profileSubscribeSectionType = "SellerProfileSubscribeSection"
	profileRichTextSectionType  = "SellerProfileRichTextSection"
	profilePostsSectionType     = "SellerProfilePostsSection"
	profileFeaturedSectionType  = "SellerProfileFeaturedProductSection"
	pageLayoutSort              = "page_layout"
	catalogPageSize             = 9
	// SearchProducts' facet sizes: Link.search_options' tags and Link.filetype_options' filetypes.
	catalogTagFacetSize      = 200
	catalogFiletypeFacetSize = 8
	// cached_default_products_section's expires_in.
	catalogTTL = 10 * time.Minute
)

// catalogSearch is section_search_results(nil): the seller's products on their profile,
// newest first, with SearchProducts' tag and filetype facets.
type catalogSearch struct {
	Total     int64           `json:"total"`
	Tags      []catalogBucket `json:"tags"`
	Filetypes []catalogBucket `json:"filetypes"`
	IDs       []int64         `json:"ids"`
}

type catalogBucket struct {
	Key      string `json:"key"`
	DocCount int64  `json:"doc_count"`
}

func bucketsProps(buckets []catalogBucket) []any {
	out := make([]any, 0, len(buckets))
	for _, b := range buckets {
		out = append(out, rails.NewRHash().Str("key", b.Key).Str("doc_count", b.DocCount))
	}
	return out
}

// storefront is whether the seller's pages render as Products/Profile/Show for a visitor who
// isn't the seller, off the Discover layout (a declined param).
func storefront(p *page) bool { return p.seller.is(userProductPageStorefrontEnabled) && !p.ownView() }

// ownView is whether the visitor is the seller, pundit_user.seller == seller: Rails then renders
// the sections in the editor's shape.
func (p *page) ownView() bool { return p.viewer != nil && p.viewer.id == p.seller.id }

// productsSection is a saved SellerProfileProductsSection, on the profile or a product.
type productsSection struct {
	id            int64
	header        any
	shownProducts []int64
	sort          string
	showFilters   bool
	updatedAt     db.NullTime
	// version moves with the row, for the search's cache key.
	version string
}

// sectionHiddenHeader is SellerProfileSection's hide_header flag.
const sectionHiddenHeader = 1 << 1

// savedProductsSections is seller_profile_products_sections.on_profile, in id order as the
// seller_id index returns them. json_data off the section schema goes to Rails.
func (h *handler) savedProductsSections(ctx context.Context, sellerID int64) ([]*productsSection, error) {
	rows, err := h.c.DB.QueryContext(ctx, "SELECT "+sectionColumns+
		" FROM seller_profile_sections WHERE seller_profile_sections.seller_id = ? AND seller_profile_sections.type = ?"+
		" AND seller_profile_sections.product_id IS NULL ORDER BY seller_profile_sections.id", sellerID, profileProductsSectionType)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*productsSection
	for rows.Next() {
		var r sectionRow
		if err := rows.Scan(r.dest()...); err != nil {
			return nil, err
		}
		s, err := r.productsSection()
		if err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

// sectionRow is a seller_profile_sections row.
type sectionRow struct {
	id           int64
	typ          string
	header, data sql.NullString
	flags        int64
	updatedAt    db.NullTime
}

const sectionColumns = "seller_profile_sections.id, seller_profile_sections.type, seller_profile_sections.header," +
	" seller_profile_sections.flags, seller_profile_sections.json_data, seller_profile_sections.updated_at"

func (r *sectionRow) dest() []any {
	return []any{&r.id, &r.typ, &r.header, &r.flags, &r.data, &r.updatedAt}
}

// hidesHeader is SellerProfileSection#hide_header?.
func (r *sectionRow) hidesHeader() bool { return r.flags&sectionHiddenHeader != 0 }

// shownHeader is cached_sections' header: nil when hide_header is set.
func (r *sectionRow) shownHeader() any {
	if r.hidesHeader() {
		return nil
	}
	return nullString(r.header)
}

// productsSection reads a products section's json_data; anything off its schema goes to Rails.
func (r *sectionRow) productsSection() (*productsSection, error) {
	j, ok := parseJSONData(r.data)
	sort, sortOK := j.get("default_product_sort").(string)
	showFilters, filtersOK := j.get("show_filters").(bool)
	shown, shownOK := j.get("shown_products").([]any)
	if _, known := sectionSortClauses[sort]; !ok || !sortOK || !known || !filtersOK || !shownOK {
		return nil, fallback("products section json_data")
	}
	ids, ok := jsonIDs(shown)
	if !ok {
		return nil, fallback("products section json_data")
	}
	s := &productsSection{id: r.id, header: r.shownHeader(), sort: sort, showFilters: showFilters, updatedAt: r.updatedAt, shownProducts: ids}
	s.version = itoa(r.id) + "-" + r.updatedAt.Time.UTC().Format(time.RFC3339Nano)
	return s, nil
}

// loadCatalog is ProductPresenter#product_page_props' storefront sections:
// ProfileSectionsPresenter#props over the seller's profile products sections, with omit_product,
// or the virtual default-products section when there are none.
func (h *handler) loadCatalog(p *page, prod *product, buyer *string) ([]any, error) {
	ctx, seller := p.Ctx, p.seller
	saved, err := h.savedProductsSections(ctx, seller.id)
	if err != nil {
		return nil, err
	}
	sections := saved
	if len(saved) == 0 {
		// default_products_section_available?
		listed, err := h.exists(ctx, "SELECT 1 FROM links WHERE links.user_id = ? AND links.purchase_disabled_at IS NULL"+
			" AND links.banned_at IS NULL AND links.deleted_at IS NULL AND (links.flags & ?) = 0 LIMIT 1", seller.id, productArchived)
		if err != nil || !listed {
			return []any{}, err
		}
		// nil is the virtual default-products section.
		sections = []*productsSection{nil}
	}
	searches, err := h.catalogSearches(p, sections)
	if err != nil {
		return nil, err
	}
	return h.productsSectionsProps(p, prod, sections, searches, buyer)
}

// reviewSorted is whether a section is ordered by reviews: a review moves that order without
// touching links.updated_at, so a search of go_web's own can differ from Rails' cache.
func reviewSorted(sections []*productsSection) bool {
	return slices.ContainsFunc(sections, func(s *productsSection) bool {
		return s != nil && (s.sort == "highest_rated" || s.sort == "most_reviewed")
	})
}

// productsSectionsProps is section_props for products sections, with omit_product unless omit
// is nil.
func (h *handler) productsSectionsProps(p *page, omit *product, sections []*productsSection, searches []*catalogSearch, buyer *string) ([]any, error) {
	seller := p.seller
	// Every section's cards load together; a product in several sections loads once.
	var ids []int64
	for _, search := range searches {
		for _, id := range search.IDs {
			if !slices.Contains(ids, id) {
				ids = append(ids, id)
			}
		}
	}
	loaded, err := h.loadCards(p, ids)
	if err != nil {
		return nil, err
	}
	byID := make(map[int64]*card, len(loaded))
	for _, c := range loaded {
		byID[c.prod.id] = c
	}
	soldOut := map[int64]bool{}
	type sectionCards struct {
		total int64
		shown []*card
	}
	built := make([]sectionCards, len(sections))
	var allShown []*card
	for i, s := range sections {
		search := searches[i]
		total, omitted := search.Total, false
		var kept []*card
		for _, id := range search.IDs {
			if omit != nil && id == omit.id {
				omitted = true
				continue
			}
			kept = append(kept, byID[id])
		}
		// omit_product: one fewer whether it was on the page or only counted beyond it, when the
		// section's search counted it.
		if omit != nil {
			counted := omit.userID == seller.id
			if s != nil {
				counted = slices.Contains(s.shownProducts, omit.id)
			}
			if omitted || omit.alive() && !omit.is(productArchived) && counted {
				total--
			}
		}
		shown := make([]*card, 0, len(kept))
		for _, c := range kept {
			// The seller sees their sold-out products.
			if !p.ownView() && c.prod.is(productHideSoldOutVariants) {
				out, seen := soldOut[c.prod.id]
				if !seen {
					if out, err = h.cardSoldOut(p, c); err != nil {
						return nil, err
					}
					soldOut[c.prod.id] = out
				}
				if out {
					total--
					continue
				}
			}
			shown = append(shown, c)
			if !slices.Contains(allShown, c) {
				allShown = append(allShown, c)
			}
		}
		built[i] = sectionCards{total, shown}
	}
	if err := h.cardThumbnails(p, allShown); err != nil {
		return nil, err
	}
	if err := h.cardOffers(p, allShown); err != nil {
		return nil, err
	}
	out := make([]any, 0, len(sections))
	for i, s := range sections {
		products := make([]any, 0, len(built[i].shown))
		for _, c := range built[i].shown {
			props, err := h.cardProps(p, c, buyer)
			if err != nil {
				return nil, err
			}
			products = append(products, props)
		}
		section := h.catalogSection(p, s, searches[i], built[i].total, products)
		if omit != nil {
			section.Sym("exclude_ids", []any{h.c.IDs.Encrypt(omit.id)})
		}
		out = append(out, section)
	}
	return out, nil
}

// catalogSection is section_props' hash for a saved products section, or for the virtual one
// when s is nil.
func (h *handler) catalogSection(p *page, s *productsSection, search *catalogSearch, total int64, products []any) *rails.RHash {
	results := rails.NewRHash().
		Sym("total", total).
		Sym("tags_data", bucketsProps(search.Tags)).
		Sym("filetypes_data", bucketsProps(search.Filetypes)).
		Sym("taxonomy_attributes_data", []any{}).
		Sym("products", products)
	var section *rails.RHash
	if s == nil {
		section = sectionHead(defaultProductsSectionID, "More from "+nameOrUsername(p.seller), profileProductsSectionType).
			Sym("show_filters", false).
			Sym("default_product_sort", pageLayoutSort)
	} else {
		section = sectionHead(h.c.IDs.Encrypt(s.id), s.header, profileProductsSectionType).
			Sym("show_filters", s.showFilters).
			Sym("default_product_sort", s.sort)
	}
	return section.Sym("search_results", results)
}

// sectionHead is the keys cached_sections starts every section with.
func sectionHead(id string, header any, typ string) *rails.RHash {
	return rails.NewRHash().Sym("id", id).Sym("header", header).Sym("type", typ)
}

// searchSections is section_search_results for each section, in order.
func (h *handler) searchSections(p *page, sections []*productsSection) ([]*catalogSearch, error) {
	searches := make([]*catalogSearch, len(sections))
	for i, s := range sections {
		var err error
		if searches[i], err = h.searchCatalog(p, s); err != nil {
			return nil, err
		}
	}
	return searches, nil
}

// cachedCatalog is cached_sections' or cached_default_products_section's searches, under one key
// of go_web's own that moves with the seller's products and with every section, as Rails' does.
// Rails never reads it, so it's written even when the page then goes to Rails.
func (h *handler) cachedCatalog(p *page, sections []*productsSection) ([]*catalogSearch, error) {
	productsKey, err := h.productsCacheKey(p)
	if err != nil {
		return nil, err
	}
	key := "go-web:storefront-catalog_" + productsKey
	if sections[0] != nil {
		var versions []string
		for _, s := range sections {
			versions = append(versions, s.version)
		}
		sum := sha256.Sum256([]byte(strings.Join(versions, "\n")))
		key += "_" + hex.EncodeToString(sum[:16])
	}
	cached, found, err := h.readCache(p.Ctx, key)
	if err != nil {
		return nil, err
	}
	if found {
		var searches []*catalogSearch
		if text, ok := cached.(string); !ok || json.Unmarshal([]byte(text), &searches) != nil || len(searches) != len(sections) {
			return nil, fallback("cached catalog")
		}
		return searches, nil
	}
	searches, err := h.searchSections(p, sections)
	if err != nil {
		return nil, err
	}
	text, err := json.Marshal(searches)
	if err != nil {
		return nil, err
	}
	if !p.DryRun {
		if err := h.c.Page.Cache.Write(context.WithoutCancel(p.Ctx), key, string(text), catalogTTL); err != nil {
			web.Logger(p.Req.HTTP).Warn("catalog cache write failed", "error", err.Error())
		}
	}
	return searches, nil
}

// sectionSortClauses is search_options' sort for a section's default_product_sort: page_layout
// orders by the boosts on shown_products, and every other key ties on created_at.
var sectionSortClauses = map[string][]any{
	pageLayoutSort:  {},
	"newest":        {desc("created_at"), desc("created_at")},
	"highest_rated": {desc("average_rating"), desc("reviews_count"), desc("created_at")},
	"most_reviewed": {desc("reviews_count"), desc("created_at")},
	"price_asc":     {map[string]any{"available_price_cents": map[string]any{"order": "asc", "mode": "min"}}, desc("created_at")},
	"price_desc":    {map[string]any{"available_price_cents": map[string]any{"order": "desc", "mode": "min"}}, desc("created_at")},
}

func desc(field string) map[string]any { return map[string]any{field: map[string]any{"order": "desc"}} }

// searchCatalog is Link.filetype_options' and Link.search_options' searches for a section. They
// share a query, so one request carries both facets.
func (h *handler) searchCatalog(p *page, section *productsSection) (*catalogSearch, error) {
	if h.c.Page.Search == nil {
		return nil, fallback("products section search")
	}
	terms := func(field string, size int) map[string]any {
		return map[string]any{"terms": map[string]any{"field": field, "size": size}}
	}
	must := []any{
		map[string]any{"terms": map[string]any{"user_id": []int64{p.seller.id}}},
		map[string]any{"term": map[string]any{"is_alive_on_profile": true}},
	}
	boolQuery := map[string]any{}
	sort := []any{desc("created_at")}
	if section != nil {
		must = append(must, map[string]any{"terms": map[string]any{"_id": section.shownProducts}})
		sort = sectionSortClauses[section.sort]
		if section.sort == pageLayoutSort {
			should := make([]any, len(section.shownProducts))
			for i, id := range section.shownProducts {
				should[i] = map[string]any{"term": map[string]any{"_id": map[string]any{"value": id, "boost": len(section.shownProducts) - i}}}
			}
			boolQuery["should"] = should
		}
	}
	boolQuery["must"] = must
	var products struct {
		Hits struct {
			Total struct {
				Value    int64  `json:"value"`
				Relation string `json:"relation"`
			} `json:"total"`
			Hits []struct {
				ID    string            `json:"_id"`
				Score json.RawMessage   `json:"_score"`
				Sort  []json.RawMessage `json:"sort"`
			} `json:"hits"`
		} `json:"hits"`
		Aggregations struct {
			Tags struct {
				Buckets []catalogBucket `json:"buckets"`
			} `json:"tags.keyword"`
			Filetypes struct {
				Buckets []catalogBucket `json:"buckets"`
			} `json:"filetypes.keyword"`
		} `json:"aggregations"`
	}
	err := h.c.Page.Search.Search(p.Ctx, "products", map[string]any{
		"query": map[string]any{"bool": boolQuery},
		"aggregations": map[string]any{"tags.keyword": terms("tags.keyword", catalogTagFacetSize),
			"filetypes.keyword": terms("filetypes.keyword", catalogFiletypeFacetSize)},
		// One hit past the page shows whether its last one ties with the next.
		"sort": sort, "size": catalogPageSize + 1, "from": 0, "_source": false, "track_total_hits": true}, &products)
	if err != nil {
		return nil, searchFailed(p, "catalog", err)
	}
	if products.Hits.Total.Relation != "eq" {
		return nil, fallback("catalog total")
	}
	s := &catalogSearch{Total: products.Hits.Total.Value, Tags: products.Aggregations.Tags.Buckets,
		Filetypes: products.Aggregations.Filetypes.Buckets, IDs: []int64{}}
	var last string
	for _, hit := range products.Hits.Hits {
		id, err := strconv.ParseInt(hit.ID, 10, 64)
		key := string(hit.Score)
		if len(sort) > 0 {
			raw, _ := json.Marshal(hit.Sort)
			key = string(raw)
		}
		if err != nil || key == "" || len(hit.Sort) != len(sort) {
			return nil, fallback("catalog hit")
		}
		if key == last {
			// Tied hits come back in whichever order a shard copy keeps them.
			return nil, fallback("catalog order")
		}
		last = key
		s.IDs = append(s.IDs, id)
	}
	if len(s.IDs) > catalogPageSize {
		s.IDs = s.IDs[:catalogPageSize]
	}
	return s, nil
}

// card is a catalog product as ProductPresenter::Card reads it.
type card struct {
	prod *product
	// defaultRecurrence is subscription_duration.to_s.
	defaultRecurrence    string
	prices               []priceRow
	minVariantDifference sql.NullInt64
	stat                 *reviewStat
	thumbnails           []thumbnailRow
	hasTier, hasPlan     bool
	thumbnailURL         any
	// tiers are a tiered membership's preloaded tiers, with their alive buy prices.
	tiers []*variantOption
	// offer is effective_default_offer_code; onSale is whether it's the seller's sale.
	offer  *offerCode
	onSale bool
}

// loadCards is section_props' Link.find of the hits, in hit order, for the shapes whose card
// this port renders.
func (h *handler) loadCards(p *page, ids []int64) ([]*card, error) {
	if len(ids) == 0 {
		return nil, nil
	}
	ctx := p.Ctx
	byID := make(map[int64]*card, len(ids))
	rows, err := h.c.DB.QueryContext(ctx, "SELECT "+productColumns+","+
		" EXISTS(SELECT 1 FROM variant_categories WHERE variant_categories.link_id = links.id AND variant_categories.deleted_at IS NULL"+
		" AND variant_categories.title = 'Tier'),"+
		" EXISTS(SELECT 1 FROM product_installment_plans WHERE product_installment_plans.link_id = links.id"+
		" AND product_installment_plans.deleted_at IS NULL)"+
		" FROM links WHERE links.id IN ("+placeholders(len(ids))+")", int64Args(ids)...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		c := &card{prod: &product{}}
		if err := rows.Scan(append(c.prod.dest(), &c.hasTier, &c.hasPlan)...); err != nil {
			return nil, err
		}
		if reason := unportedCard(p.seller.id, c.prod); reason != "" {
			return nil, fallback("catalog " + reason)
		}
		var ok bool
		if c.defaultRecurrence, ok = c.prod.subscriptionDurationName(); !ok || c.defaultRecurrence == "" && c.prod.is(productIsTieredMembership) {
			// lowest_tier_price would compare the tier prices with a nil duration.
			return nil, fallback("catalog subscription duration")
		}
		byID[c.prod.id] = c
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	rows.Close()
	cards := make([]*card, len(ids))
	for i, id := range ids {
		if cards[i] = byID[id]; cards[i] == nil {
			// Link.find raises.
			return nil, fallback("catalog product missing")
		}
	}
	prices, err := h.alivePrices(ctx, ids)
	if err != nil {
		return nil, err
	}
	stats, err := h.reviewStats(ctx, ids)
	if err != nil {
		return nil, err
	}
	floors, err := h.variantPriceFloors(ctx, ids)
	if err != nil {
		return nil, err
	}
	thumbnails, err := h.aliveThumbnails(ctx, ids)
	if err != nil {
		return nil, err
	}
	tiers, err := h.cardTiers(p, cards)
	if err != nil {
		return nil, err
	}
	for id, c := range byID {
		c.prices, c.stat, c.minVariantDifference, c.thumbnails, c.tiers = prices[id], stats[id], floors[id], thumbnails[id], tiers[id]
	}
	return cards, nil
}

// cardTiers is the tiers preload for the tiered memberships among the cards: each alive
// Variant in an alive Tier category, with its alive buy prices and whether it's closed.
func (h *handler) cardTiers(p *page, cards []*card) (map[int64][]*variantOption, error) {
	var ids []int64
	for _, c := range cards {
		if c.prod.is(productIsTieredMembership) {
			ids = append(ids, c.prod.id)
		}
	}
	if len(ids) == 0 {
		return nil, nil
	}
	out := map[int64][]*variantOption{}
	rows, err := h.c.DB.QueryContext(p.Ctx, "SELECT variant_categories.link_id, base_variants.id, base_variants.flags,"+
		" base_variants.customizable_price FROM base_variants INNER JOIN variant_categories ON variant_categories.id = base_variants.variant_category_id"+
		" WHERE base_variants.type = 'Variant' AND base_variants.deleted_at IS NULL AND variant_categories.deleted_at IS NULL"+
		" AND variant_categories.title = 'Tier' AND variant_categories.link_id IN ("+placeholders(len(ids))+")", int64Args(ids)...)
	if err != nil {
		return nil, err
	}
	var all []*variantOption
	for rows.Next() {
		var productID int64
		o := &variantOption{}
		if err := rows.Scan(&productID, &o.id, &o.flags, &o.customizablePrice); err != nil {
			rows.Close()
			return nil, err
		}
		out[productID] = append(out[productID], o)
		all = append(all, o)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if err := h.loadTierPrices(p.Ctx, all); err != nil {
		return nil, err
	}
	return out, h.markClosedTiers(p.Ctx, p.seller.id, all)
}

// variantPriceFloors is lowest_variant_price_difference_cents over each product's
// preloaded_options: its alive SKUs, the default one included, and its alive categories' alive
// variants.
func (h *handler) variantPriceFloors(ctx context.Context, ids []int64) (map[int64]sql.NullInt64, error) {
	in := placeholders(len(ids))
	rows, err := h.c.DB.QueryContext(ctx, "SELECT options.link_id, MIN(options.price_difference_cents) FROM ("+
		"SELECT variant_categories.link_id, base_variants.price_difference_cents FROM base_variants"+
		" INNER JOIN variant_categories ON variant_categories.id = base_variants.variant_category_id"+
		" WHERE base_variants.type = 'Variant' AND base_variants.deleted_at IS NULL AND variant_categories.deleted_at IS NULL"+
		" AND variant_categories.link_id IN ("+in+")"+
		" UNION ALL SELECT base_variants.link_id, base_variants.price_difference_cents FROM base_variants"+
		" WHERE base_variants.type = 'Sku' AND base_variants.deleted_at IS NULL AND base_variants.link_id IN ("+in+")"+
		") options GROUP BY options.link_id", append(int64Args(ids), int64Args(ids)...)...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[int64]sql.NullInt64{}
	for rows.Next() {
		var id int64
		var floor sql.NullInt64
		if err := rows.Scan(&id, &floor); err != nil {
			return nil, err
		}
		out[id] = floor
	}
	return out, rows.Err()
}

// aliveThumbnails is each product's thumbnail_alive rows.
func (h *handler) aliveThumbnails(ctx context.Context, ids []int64) (map[int64][]thumbnailRow, error) {
	rows, err := h.c.DB.QueryContext(ctx, "SELECT thumbnails.product_id, thumbnails.id, thumbnails.unsplash_url FROM thumbnails"+
		" WHERE thumbnails.deleted_at IS NULL AND thumbnails.product_id IN ("+placeholders(len(ids))+")", int64Args(ids)...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[int64][]thumbnailRow{}
	for rows.Next() {
		var id int64
		var t thumbnailRow
		if err := rows.Scan(&id, &t.id, &t.unsplash); err != nil {
			return nil, err
		}
		out[id] = append(out[id], t)
	}
	return out, rows.Err()
}

// unportedCard is a catalog product whose card this port leaves to Rails.
func unportedCard(sellerID int64, prod *product) string {
	_, known := currencies[prod.productCurrency()]
	switch {
	case prod.userID != sellerID:
		// url_for_product_page and the seller's auto-apply code are the subdomain seller's.
		return "seller"
	case !prod.purchaseType.Valid || prod.purchaseType.Int64 < purchaseTypeBuyOnly || prod.purchaseType.Int64 > purchaseTypeBuyAndRent:
		return "purchase type"
	case !prod.priceCurrencyType.Valid || !known:
		return "currency"
	}
	return ""
}

// cardSoldOut is hide_sold_out_variants? && remaining_for_sale_count == 0.
func (h *handler) cardSoldOut(p *page, c *card) (bool, error) {
	if c.hasTier || c.prod.is(productIsBundle) {
		return false, fallback("catalog inventory")
	}
	vs, err := h.loadVariants(p.Ctx, c.prod)
	if err != nil {
		return false, err
	}
	remaining, err := h.remainingForSaleCount(p.Ctx, c.prod, vs, nil)
	return remaining == int64(0), err
}

// cardProps is ProductPresenter::Card#for_web for section_props: no seller, inventory or
// description, and a product URL on this subdomain with layout=profile.
func (h *handler) cardProps(p *page, c *card, buyer *string) (*rails.RHash, error) {
	prod := c.prod
	// display_price_cents(for_default_duration: true).
	var price int64
	pwyw := prod.customizablePrice.Bool
	if prod.is(productIsTieredMembership) {
		offered := offeredTiers(c.tiers)
		price = lowestTierPriceCents(offered, &c.defaultRecurrence)
		// has_customizable_price_option?
		pwyw = slices.ContainsFunc(offered, func(o *variantOption) bool { return o.customizablePrice.Bool })
	} else {
		var rows []priceRow
		for _, r := range c.prices {
			if r.atDuration(prod, c.defaultRecurrence) {
				rows = append(rows, r)
			}
		}
		// default_price_cents: a rent-only product's is its rental price.
		last, agreed := lastPrice(pricesForCurrency(prod, rows, prod.rentOnly()))
		if !agreed {
			return nil, fallback("catalog price")
		}
		if last != nil {
			price = *last
		}
		price += c.minVariantDifference.Int64
	}
	// default_price_recurrence: every match has the recurrence it matched on.
	var recurrence any
	for _, r := range c.prices {
		if r.recurrence.Valid && r.recurrence.String == c.defaultRecurrence {
			recurrence = r.recurrence.String
			break
		}
	}
	base := price
	price, err := h.cardPriceCents(p, c, base)
	if err != nil {
		return nil, err
	}
	ratings := cardRatings(prod, c.stat)
	pc := prod.productCurrency()
	var display *currencyDisplay
	if buyer != nil {
		if display, err = h.currencyDisplayFor(p, prod, c.hasPlan, *buyer, &price); err != nil {
			return nil, err
		}
	}
	if display != nil && price < base {
		display.setOriginal(base, pc)
	}
	externalID := h.c.IDs.Encrypt(prod.id)
	props := rails.NewRHash().
		Sym("id", externalID).
		Sym("permalink", nullString(prod.uniquePermalink)).
		Sym("name", prod.name).
		Sym("seller", nil).
		Sym("ratings", ratings).
		Sym("thumbnail_url", c.thumbnailURL).
		Sym("native_type", prod.nativeType).
		Sym("quantity_remaining", nil).
		Sym("is_sales_limited", false).
		Sym("price_cents", price).
		Sym("currency_code", pc).
		Sym("buyer_currency_display", buyerCurrencyDisplay(externalID, pc, display))
	buyerLocalPriceProps(props, pc, display)
	// url_for_product_page on the seller's own subdomain, whose port declined() rules out.
	url := web.Protocol(p.Req.HTTP) + p.Req.Host + "/l/" + web.EscapeSegment(prod.generalPermalink()) + "?layout=profile"
	props.Sym("is_pay_what_you_want", pwyw).
		Sym("url", url).
		Sym("duration_in_months", nullInt(prod.durationInMonths)).
		Sym("recurrence", recurrence)
	if price < base {
		props.Sym("original_price_cents", base)
		// auto_apply_sale_label.
		if c.onSale {
			props.Sym("sale_label", c.offer.displayedSaleLabel())
		}
	}
	return props, nil
}

// cardThumbnails is thumbnail_or_cover_url for each card: thumbnail_alive&.url, else the
// first image cover's url.
func (h *handler) cardThumbnails(p *page, cards []*card) error {
	var thumbnails []thumbnailRow
	for _, c := range cards {
		if len(c.thumbnails) > 1 {
			// has_one's preload keeps whichever row MySQL returns first.
			return fallback("catalog thumbnails")
		}
		thumbnails = append(thumbnails, c.thumbnails...)
	}
	thumbnailURLs, err := h.thumbnailURLs(p.Ctx, thumbnails)
	if err != nil {
		return err
	}
	var uncovered []int64
	for _, c := range cards {
		if len(c.thumbnails) == 1 {
			if c.thumbnailURL = thumbnailURLs[c.thumbnails[0].id]; c.thumbnailURL != nil {
				continue
			}
		}
		uncovered = append(uncovered, c.prod.id)
	}
	if len(uncovered) == 0 {
		return nil
	}
	urls, err := h.firstImageCoverURLs(p, uncovered)
	if err != nil {
		return err
	}
	for _, c := range cards {
		if url, ok := urls[c.prod.id]; ok {
			c.thumbnailURL = url
		}
	}
	return nil
}

// firstImageCoverURLs is display_asset_previews.find(&:image_url?)&.url for each product. Only
// that cover's URL is read, as Rails reads it.
func (h *handler) firstImageCoverURLs(p *page, ids []int64) (map[int64]string, error) {
	rows, err := h.c.DB.QueryContext(p.Ctx, `SELECT asset_previews.link_id, asset_previews.id, asset_previews.position,
		asset_previews.created_at, asset_previews.unsplash_url, asset_previews.oembed IS NOT NULL, att.id, blobs.id, blobs.key,
		blobs.filename, blobs.content_type, blobs.metadata
		FROM asset_previews
		LEFT JOIN active_storage_attachments att ON att.record_type = 'AssetPreview' AND att.record_id = asset_previews.id
			AND att.name = 'file'
		LEFT JOIN active_storage_blobs blobs ON blobs.id = att.blob_id
		WHERE asset_previews.link_id IN (`+placeholders(len(ids))+`) AND asset_previews.deleted_at IS NULL
		ORDER BY asset_previews.link_id, asset_previews.position ASC, asset_previews.created_at ASC, asset_previews.id ASC,
			att.blob_id ASC`, int64Args(ids)...)
	if err != nil {
		return nil, err
	}
	type preview struct {
		id, productID        int64
		order                coverOrder
		unsplash             sql.NullString
		oembed               bool
		attID, blobID        sql.NullInt64
		key, filename, ctype sql.NullString
		metadata             sql.NullString
	}
	var previews []preview
	for rows.Next() {
		var r preview
		if err := rows.Scan(&r.productID, &r.id, &r.order.position, &r.order.createdAt, &r.unsplash, &r.oembed, &r.attID, &r.blobID,
			&r.key, &r.filename, &r.ctype, &r.metadata); err != nil {
			rows.Close()
			return nil, err
		}
		if n := len(previews); n > 0 && previews[n-1].id == r.id {
			// has_one keeps the lowest blob_id.
			continue
		}
		if r.attID.Valid && !r.blobID.Valid {
			rows.Close()
			return nil, fallback("cover attachment")
		}
		previews = append(previews, r)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	imageURL := func(r preview) bool {
		return rails.Present(r.unsplash.String) || r.attID.Valid && strings.HasPrefix(r.ctype.String, "image")
	}
	urls := map[int64]string{}
	for _, r := range previews {
		if _, done := urls[r.productID]; done || !imageURL(r) {
			continue
		}
		for _, o := range previews {
			if o.productID == r.productID && o.id != r.id && o.order == r.order && imageURL(o) {
				return nil, fallback("cover order")
			}
		}
		switch {
		case rails.Present(r.unsplash.String):
			urls[r.productID] = r.unsplash.String
			continue
		case r.oembed:
			return nil, fallback("oembed cover")
		}
		c := &cover{attachmentID: r.attID.Int64, blobID: r.blobID.Int64, key: r.key.String, filename: r.filename.String,
			contentType: r.ctype.String, postProcess: !strings.Contains(r.ctype.String, "gif")}
		if c.width, c.height, err = blobDimensions(r.metadata.String); err != nil {
			return nil, fallback("cover metadata")
		}
		var url string
		if c.postProcess {
			url, err = h.retinaCoverURL(p.Ctx, p, c)
		} else {
			url, err = h.originalCoverURL(p.Ctx, p, c)
		}
		if err != nil {
			return nil, err
		}
		urls[r.productID] = url
	}
	return urls, nil
}
