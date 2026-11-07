package products

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"slices"
	"strconv"
	"strings"

	"github.com/antiwork/gumroad/go_web/internal/inertia"
	"github.com/antiwork/gumroad/go_web/internal/pages"
	"github.com/antiwork/gumroad/go_web/internal/rails"
)

const (
	// autocompleteData is the partial reload show answers itself, on layout=discover.
	autocompleteData = "autocomplete_results"
	// Discover::AutocompletePresenter's PRODUCT_RESULT_COUNT, which is also partial_search_options'
	// MAX_PARTIAL_SEARCH_RESULTS, and RECENT_SEARCH_LIMIT; then the recent searches it keeps for a
	// blank and a typed query.
	autocompleteProductCount  = 5
	recentSearchLimit         = 100
	recentSearchesForBlank    = 5
	recentSearchesForTyped    = 8
	autocompleteRecommendedBy = "search"
	// Link::MAX_NUMBER_OF_TAGS, search_options' tags aggregation off a profile.
	discoverTagFacetSize = 9
)

// renderAutocomplete is show's layout=discover answer to Discover's search box: the
// before_actions and show up to respond_to, then Discover::AutocompletePresenter's props alone.
// The share blocks still run, and the meta tags ride along as _inertia_meta.
func (h *handler) renderAutocomplete(w http.ResponseWriter, p *page, prod *product) error {
	if p.layout != productLayoutDiscover || p.iframe || p.wanted {
		return fallback("inertia partial reload")
	}
	pc, ctx := h.c.Page, p.Ctx
	v, err := h.loadMetaView(ctx, p, prod)
	if err != nil {
		return err
	}
	meta, err := h.productMeta(p, prod, v)
	if err != nil {
		return err
	}
	// create_discover_search! runs before respond_to, so a typed query's suggestion is the newest
	// the presenter reads; this port writes it after the reads.
	record, err := h.recordsDiscoverSearch(p)
	if err != nil {
		return err
	}
	var pending any
	if typed, _ := p.query.(string); record && rails.Present(typed) && p.Req.Param("autocomplete") != "true" {
		pending = typed
	}
	results, err := h.autocompleteResults(p, pending)
	if err != nil {
		return err
	}
	// The share block reads the CSRF token and the flash whatever the reload keeps, and the
	// renderer always keeps its errors.
	shared, err := pc.Shared.SignedOut(ctx, pages.Request{
		Req: p.Req, Session: p.Session, CSRFToken: p.MaskedCSRFToken(), Title: meta.PageTitle(h.c.Meta.Title),
	})
	if errors.Is(err, pages.ErrUnported) {
		return fallback("shared props")
	}
	if err != nil {
		return err
	}
	keepMetaCoverWrites(p, v.covers)
	if err := h.finishShow(w, p, prod, v.ip); err != nil {
		return err
	}
	// The csp_nonce share is a lambda the reload never calls, so the policy gets no nonce.
	w.Header().Set("Content-Security-Policy", pc.CSP.Header(""))
	props := rails.NewRHash().Sym("errors", shared.Get("errors")).Sym(autocompleteData, results).Sym("_inertia_meta", meta.JSON())
	rails.RenderInertiaJSON(w, p.Req, inertia.Page(discoverComponent, p.Req.FullPath(), props))
	return nil
}

// loadMetaView reads what prepare_product_page's and set_favicon_meta_tags' tags read.
func (h *handler) loadMetaView(ctx context.Context, p *page, prod *product) (*view, error) {
	v := &view{}
	var ok bool
	if v.productJSON, ok = parseJSONData(prod.jsonData); !ok {
		return nil, fallback("product json_data")
	}
	v.ip, _ = p.Req.RemoteIP()
	var err error
	if v.avatarURL, err = h.avatarURL(p, p.seller.id); err != nil {
		return nil, err
	}
	if v.prices, err = h.loadPrices(ctx, prod); err != nil {
		return nil, err
	}
	v.priceCents = v.prices.buy
	if prod.rentOnly() {
		v.priceCents = v.prices.rental
	}
	if v.covers, err = h.loadCovers(ctx, p, prod.id); err != nil {
		return nil, err
	}
	if v.files, err = h.aliveProductFiles(ctx, prod.id); err != nil {
		return nil, err
	}
	if v.reviewStat, err = h.loadReviewStat(ctx, prod.id); err != nil {
		return nil, err
	}
	if v.variants, err = h.loadVariants(ctx, prod); err != nil {
		return nil, err
	}
	if v.bundle, err = h.loadBundle(ctx, p, prod); err != nil {
		return nil, err
	}
	if v.quantityRemaining, err = h.remainingForSaleCount(ctx, prod, v.variants, v.bundle.quantityLeft); err != nil {
		return nil, err
	}
	if err := h.loadDescription(ctx, prod, v); err != nil {
		return nil, err
	}
	if err := h.loadCustomStyles(ctx, p, v); err != nil {
		return nil, err
	}
	return v, nil
}

// autocompleteResults is Discover::AutocompletePresenter#props for the visitor and
// params[:query]; pending is the suggestion show records first, nil for none.
func (h *handler) autocompleteResults(p *page, pending any) (*rails.RHash, error) {
	raw, _ := p.query.(string)
	query := rails.Downcase(raw)
	recent, err := h.recentSearches(p, query, pending)
	if err != nil {
		return nil, err
	}
	out := rails.NewRHash().Sym("recent_searches", recent)
	if rails.Present(query) {
		products, err := h.autocompleteProducts(p, query, partialSearchBody(query))
		return out.Sym("products", products), err
	}
	var ids []any
	if p.viewer != nil || rails.Present(p.GUID) {
		if ids, err = h.recentlyViewed(p); err != nil {
			return nil, err
		}
	}
	viewed := len(ids) > 0
	body := discoverSearchBody(autocompleteProductCount, nil)
	if viewed {
		body = discoverSearchBody(catalogPageSize, ids)
	}
	products, err := h.autocompleteProducts(p, query, body)
	if err != nil {
		return nil, err
	}
	return out.Sym("products", products).Sym("viewed", viewed), nil
}

// recentSearches is recent_searches: DiscoverSearchSuggestion.by_user_or_browser's queries,
// by Rails' own statements, whose DISTINCT and ORDER BY only MySQL can settle.
func (h *handler) recentSearches(p *page, query string, pending any) ([]any, error) {
	where, arg := "`discover_searches`.`browser_guid` = ? AND `discover_searches`.`user_id` IS NULL", any(p.GUID)
	if p.viewer != nil {
		where, arg = "`discover_searches`.`user_id` = ?", p.viewer.id
	}
	from := " FROM `discover_search_suggestions` INNER JOIN `discover_searches` ON `discover_searches`.`id` =" +
		" `discover_search_suggestions`.`discover_search_id` WHERE `discover_search_suggestions`.`deleted_at` IS NULL AND " + where +
		" ORDER BY `discover_search_suggestions`.`created_at` DESC LIMIT "
	if rails.Blank(query) {
		return h.pluckQueries(p.Ctx, "SELECT DISTINCT `discover_searches`.`query`"+from+strconv.Itoa(recentSearchesForBlank), arg)
	}
	searches, err := h.pluckQueries(p.Ctx, "SELECT `discover_searches`.`query`"+from+strconv.Itoa(recentSearchLimit), arg)
	if err != nil {
		return nil, err
	}
	if pending != nil {
		searches = append([]any{pending}, searches[:min(len(searches), recentSearchLimit-1)]...)
	}
	queryWords := asciiFields(query)
	kept := []any{}
	for _, s := range uniqAny(searches) {
		search, ok := s.(string)
		if !ok {
			// nil.downcase raises.
			return nil, fallback("recent search without a query")
		}
		search = rails.Downcase(search)
		words := asciiFields(search)
		if slices.ContainsFunc(words, func(w string) bool { return slices.Contains(queryWords, w) || strings.HasPrefix(w, query) }) ||
			strings.HasPrefix(query, search) {
			kept = append(kept, s)
		}
	}
	return kept[:min(len(kept), recentSearchesForTyped)], nil
}

// pluckQueries is a pluck of discover_searches.query: strings, nil for NULL.
func (h *handler) pluckQueries(ctx context.Context, query string, args ...any) ([]any, error) {
	rows, err := h.c.DB.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []any{}
	for rows.Next() {
		var q sql.NullString
		if err := rows.Scan(&q); err != nil {
			return nil, err
		}
		out = append(out, nullString(q))
	}
	return out, rows.Err()
}

// uniqAny is Array#uniq over strings and nil.
func uniqAny(values []any) []any {
	out := []any{}
	for _, v := range values {
		if !slices.Contains(out, v) {
			out = append(out, v)
		}
	}
	return out
}

// asciiFields is String#split with no pattern: runs of ASCII whitespace, leading ones dropped.
func asciiFields(s string) []string {
	return strings.FieldsFunc(s, func(r rune) bool { return r == ' ' || r >= '\t' && r <= '\r' })
}

// partialSearchBody is Link.partial_search_options(query:).
func partialSearchBody(query string) map[string]any {
	return map[string]any{
		"query": map[string]any{"bool": map[string]any{"must": []any{
			map[string]any{"simple_query_string": map[string]any{"query": query, "fields": []string{"name", "name.ngrams"}, "default_operator": "and"}},
			map[string]any{"term": map[string]any{"is_recommendable": true}},
			map[string]any{"term": map[string]any{"rated_as_adult": false}},
		}}},
		"sort": []any{desc("sales_volume"), desc("created_at")},
		"size": autocompleteProductCount,
	}
}

// discoverSearchBody is Link.search_options(size:) or (ids:): Discover's recommendable products,
// featured first.
func discoverSearchBody(size int, ids []any) map[string]any {
	must := []any{
		map[string]any{"term": map[string]any{"is_recommendable": true}},
		map[string]any{"term": map[string]any{"rated_as_adult": false}},
	}
	if len(ids) > 0 {
		must = append(must, map[string]any{"terms": map[string]any{"_id": ids}})
	}
	return map[string]any{
		"query":        map[string]any{"bool": map[string]any{"must": must}},
		"aggregations": map[string]any{"tags.keyword": map[string]any{"terms": map[string]any{"field": "tags.keyword", "size": discoverTagFacetSize}}},
		"sort":         []any{desc("total_fee_cents"), desc("sales_volume"), desc("created_at")},
		"size":         size, "from": 0, "_source": false,
	}
}

// recentlyViewed is the product_id of the visitor's five latest ProductPageView documents: the
// user's, else the signed-out browser's.
func (h *handler) recentlyViewed(p *page) ([]any, error) {
	if h.c.Page.Search == nil {
		return nil, fallback("autocomplete search")
	}
	boolQuery := map[string]any{
		"must":     map[string]any{"term": map[string]any{"browser_guid": p.GUID}},
		"must_not": map[string]any{"exists": map[string]any{"field": "user_id"}},
	}
	if p.viewer != nil {
		boolQuery = map[string]any{"must": map[string]any{"term": map[string]any{"user_id": p.viewer.id}}}
	}
	var res struct {
		Hits struct {
			Hits []struct {
				Source struct {
					ProductID json.Number `json:"product_id"`
				} `json:"_source"`
			} `json:"hits"`
		} `json:"hits"`
	}
	err := h.c.Page.Search.Search(p.Ctx, "product_page_views", map[string]any{
		"query": map[string]any{"bool": boolQuery}, "sort": map[string]any{"timestamp": "desc"}, "size": autocompleteProductCount}, &res)
	if err != nil {
		return nil, searchFailed(p, "product page views", err)
	}
	ids := make([]any, 0, len(res.Hits.Hits))
	for _, hit := range res.Hits.Hits {
		id, err := hit.Source.ProductID.Int64()
		if err != nil {
			return nil, fallback("product page view")
		}
		ids = append(ids, id)
	}
	return ids, nil
}

// autocompleteProducts is search_results: the hits' records in hit order, each with its
// Discover URL, its seller's name and its thumbnail.
func (h *handler) autocompleteProducts(p *page, query string, body map[string]any) ([]any, error) {
	if h.c.Page.Search == nil {
		return nil, fallback("autocomplete search")
	}
	var res struct {
		Hits struct {
			Hits []struct {
				ID string `json:"_id"`
			} `json:"hits"`
		} `json:"hits"`
	}
	if err := h.c.Page.Search.Search(p.Ctx, "products", body, &res); err != nil {
		return nil, searchFailed(p, "autocomplete", err)
	}
	out := []any{}
	if len(res.Hits.Hits) == 0 {
		return out, nil
	}
	ids := make([]int64, 0, len(res.Hits.Hits))
	for _, hit := range res.Hits.Hits {
		id, err := strconv.ParseInt(hit.ID, 10, 64)
		if err != nil {
			return nil, fallback("autocomplete hit")
		}
		ids = append(ids, id)
	}
	type record struct {
		id, userID                    int64
		name, uniquePermalink, custom sql.NullString
	}
	byID := map[int64]*record{}
	rows, err := h.c.DB.QueryContext(p.Ctx, "SELECT links.id, links.user_id, links.name, links.unique_permalink, links.custom_permalink"+
		" FROM links WHERE links.id IN ("+placeholders(len(ids))+")", int64Args(ids)...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		r := &record{}
		if err := rows.Scan(&r.id, &r.userID, &r.name, &r.uniquePermalink, &r.custom); err != nil {
			return nil, err
		}
		byID[r.id] = r
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	rows.Close()
	urlQuery := [][2]string{{"autocomplete", "true"}, {"layout", productLayoutDiscover}, {"recommended_by", autocompleteRecommendedBy}}
	if rails.Present(query) {
		urlQuery = append(urlQuery, [2]string{"query", query})
	}
	sellers := map[int64]*user{}
	// A product the database no longer has drops out, as records does.
	for _, id := range ids {
		r, ok := byID[id]
		if !ok {
			continue
		}
		seller, ok := sellers[r.userID]
		if !ok {
			seller = &user{}
			err := h.c.DB.QueryRowContext(p.Ctx, "SELECT "+userColumns+" FROM users WHERE users.id = ? LIMIT 1", r.userID).Scan(seller.dest()...)
			if errors.Is(err, sql.ErrNoRows) {
				// product.user.name raises.
				return nil, fallback("autocomplete seller")
			}
			if err != nil {
				return nil, err
			}
			sellers[r.userID] = seller
		}
		if !r.name.Valid {
			return nil, fallback("autocomplete product name")
		}
		permalink := r.uniquePermalink.String
		if rails.Present(r.custom.String) {
			permalink = r.custom.String
		}
		thumbnail, err := h.anyThumbnailURL(p.Ctx, r.id)
		if err != nil {
			return nil, err
		}
		out = append(out, rails.NewRHash().
			Sym("name", r.name.String).
			Sym("url", h.c.Env.ProductLongURL(sellerUsername(seller), permalink)+"?"+rails.ToQuery(urlQuery...)).
			Sym("seller_name", presence(seller.name.String)).
			Sym("thumbnail_url", thumbnail))
	}
	return out, nil
}

// anyThumbnailURL is product.thumbnail&.url, by has_one's own unordered statement: a deleted
// thumbnail still has one.
func (h *handler) anyThumbnailURL(ctx context.Context, productID int64) (any, error) {
	var found *thumbnailRow
	err := scanNamed(ctx, h.c.DB, func(cols map[string]any) func() {
		t := &thumbnailRow{}
		cols["id"], cols["unsplash_url"] = &t.id, &t.unsplash
		return func() { found = t }
	}, "SELECT `thumbnails`.* FROM `thumbnails` WHERE `thumbnails`.`product_id` = ? LIMIT 1", productID)
	if err != nil || found == nil {
		return nil, err
	}
	return h.thumbnailRowURL(ctx, *found)
}
