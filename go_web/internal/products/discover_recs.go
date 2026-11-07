package products

import (
	"cmp"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"maps"
	"math/rand/v2"
	"slices"
	"time"

	"github.com/redis/go-redis/v9"

	"github.com/antiwork/gumroad/go_web/internal/rails"
	"github.com/antiwork/gumroad/go_web/internal/web"
)

const (
	// DiscoverCuratedProducts::CURATED_PRODUCTS_TIMEOUT_SECONDS.
	curatedProductsTimeout = 10 * time.Second
	// RecommendedProducts::BaseService::NUMBER_OF_RESULTS.
	recommendedProductsLimit = 40
	// RedisKey.recommended_products_associated_product_ids_limit, and its default.
	associatedProductIDsLimitKey = "recommended_products_associated_product_ids_limit"
	associatedProductIDsLimit    = 100
	// SalesRelatedProductsInfo.related_products' each_slice.
	relatedProductsSlice = 100
	// Keeps the exclusions' bundle lookup under MySQL's IN-list range-optimizer cliff.
	bundleLookupSlice = 1000
)

// curatedTaxonomyIDs is curated_products' taxonomy ids, in order. Rails rescues every error,
// and its timeout, into no products; a fallback still falls back.
func (h *handler) curatedTaxonomyIDs(p *page) ([]int64, error) {
	ctx, cancel := context.WithTimeout(p.Ctx, curatedProductsTimeout)
	defer cancel()
	ids, err := h.curatedProducts(ctx, p)
	var f fallback
	switch {
	case errors.As(err, &f):
		return nil, err
	case err != nil:
		web.Logger(p.Req.HTTP).Warn("curated products failed", "error", err.Error())
		return nil, nil
	}
	return ids, nil
}

// curatedProducts is RecommendedProducts::DiscoverService's products, as their taxonomy ids.
func (h *handler) curatedProducts(ctx context.Context, p *page) ([]int64, error) {
	cart, err := h.cartProductIDs(ctx, p)
	if err != nil || p.viewer == nil && len(cart) == 0 {
		return nil, err
	}
	limit := int64(associatedProductIDsLimit)
	if raw, err := h.c.Page.Redis.Get(ctx, associatedProductIDsLimitKey).Result(); err == nil {
		limit = rubyToI(raw)
	} else if !errors.Is(err, redis.Nil) {
		return nil, err
	}
	if limit < 0 {
		// Array#take raises.
		return nil, errors.New("negative associated product ids limit")
	}
	// purchased_products.order(succeeded_at: :desc).ids, as Rails writes it.
	const purchasedQuery = "SELECT DISTINCT `links`.`id` FROM `links` INNER JOIN `purchases` ON `links`.`id` = `purchases`.`link_id`" +
		" WHERE `purchases`.`purchaser_id` = ? ORDER BY `succeeded_at` DESC"
	var purchased []int64
	if p.viewer != nil {
		if purchased, err = h.scanIDs(ctx, purchasedQuery+" LIMIT ?", p.viewer.id, limit); err != nil {
			return nil, err
		}
	}
	associated := union(cart[:min(int64(len(cart)), limit)], purchased)
	if len(associated) >= 4 {
		// Array#sample of half of them. A dry run takes the first half, which a parity run stubs
		// Rails' sample to match.
		half := len(associated) / 2
		if p.DryRun {
			associated = associated[:half]
		} else {
			sampled := make([]int64, 0, half)
			for _, i := range rand.Perm(len(associated))[:half] {
				sampled = append(sampled, associated[i])
			}
			associated = sampled
		}
	}
	related, err := h.relatedProducts(ctx, associated)
	if err != nil || len(related) == 0 {
		return nil, err
	}
	// Every purchase only matters as a set, which a LIMIT that cut nothing already holds.
	allPurchased := purchased
	if p.viewer != nil && int64(len(purchased)) == limit {
		if allPurchased, err = h.scanIDs(ctx, purchasedQuery, p.viewer.id); err != nil {
			return nil, err
		}
	}
	excluded, err := h.excludedProductIDs(ctx, cart, allPurchased)
	if err != nil {
		return nil, err
	}
	related = slices.DeleteFunc(related, func(id int64) bool { return excluded[id] })
	if len(related) == 0 {
		return nil, nil
	}
	return h.recommendedTaxonomyIDs(ctx, related)
}

// cartProductIDs is Cart.fetch_by's alive cart products: the signed-in visitor's first alive
// cart, else the browser's guest cart.
func (h *handler) cartProductIDs(ctx context.Context, p *page) ([]int64, error) {
	var row *sql.Row
	switch {
	case p.viewer != nil:
		row = h.c.DB.QueryRowContext(ctx, "SELECT `carts`.`id` FROM `carts` WHERE `carts`.`user_id` = ?"+
			" AND `carts`.`deleted_at` IS NULL ORDER BY `carts`.`id` ASC LIMIT 1", p.viewer.id)
	case rails.Blank(p.GUID):
		return nil, nil
	default:
		row = h.c.DB.QueryRowContext(ctx, "SELECT `carts`.`id` FROM `carts` WHERE `carts`.`deleted_at` IS NULL"+
			" AND `carts`.`browser_guid` = ? AND `carts`.`user_id` IS NULL LIMIT 1", p.GUID)
	}
	var cartID int64
	if err := row.Scan(&cartID); errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	} else if err != nil {
		return nil, err
	}
	return h.scanIDs(ctx, "SELECT `cart_products`.`product_id` AS id FROM `cart_products` WHERE `cart_products`.`cart_id` = ?"+
		" AND `cart_products`.`deleted_at` IS NULL", cartID)
}

// relatedProducts is SalesRelatedProductsInfo.related_products' ids: the cached sales counts
// summed across the products, without them, by count and then id, both descending.
func (h *handler) relatedProducts(ctx context.Context, ids []int64) ([]int64, error) {
	counts := map[int64]int64{}
	for chunk := range slices.Chunk(ids, relatedProductsSlice) {
		var sumErr error
		err := scanNamed(ctx, h.c.DB, func(cols map[string]any) func() {
			var raw sql.NullString
			cols["counts"] = &raw
			return func() { sumErr = cmp.Or(sumErr, sumCounts(raw, counts)) }
		}, "SELECT `cached_sales_related_products_infos`.* FROM `cached_sales_related_products_infos`"+
			" WHERE `cached_sales_related_products_infos`.`product_id` IN ("+placeholders(len(chunk))+")", int64Args(chunk)...)
		if err = cmp.Or(err, sumErr); err != nil {
			return nil, err
		}
	}
	for _, id := range ids {
		delete(counts, id)
	}
	related := slices.SortedFunc(maps.Keys(counts), func(a, b int64) int {
		return cmp.Or(cmp.Compare(counts[b], counts[a]), cmp.Compare(b, a))
	})
	return related[:min(len(related), recommendedProductsLimit)], nil
}

// sumCounts adds normalized_counts to counts.
func sumCounts(raw sql.NullString, counts map[int64]int64) error {
	j, ok := parseJSONData(raw)
	if !ok {
		return errors.New("related products counts")
	}
	if j.h == nil {
		return nil
	}
	for _, key := range j.h.Keys() {
		n, isNumber := j.h.Value(key).(json.Number)
		if !isNumber {
			// Integer#+ raises on a String or nil.
			return errors.New("related products count")
		}
		count, err := n.Int64()
		if err != nil {
			// A Float or a Bignum would still sum in Ruby.
			return fallback("related products count")
		}
		id, _ := rails.StringToI(key)
		counts[id] += count
	}
	return nil
}

// excludedProductIDs is exclude_product_ids: what the visitor has and their bundles hold.
func (h *handler) excludedProductIDs(ctx context.Context, cart, purchased []int64) (map[int64]bool, error) {
	excluded := map[int64]bool{}
	for _, id := range slices.Concat(cart, purchased) {
		excluded[id] = true
	}
	for chunk := range slices.Chunk(slices.Collect(maps.Keys(excluded)), bundleLookupSlice) {
		bundled, err := h.scanIDs(ctx, "SELECT DISTINCT `bundle_products`.`product_id` AS id FROM `bundle_products`"+
			" WHERE `bundle_products`.`deleted_at` IS NULL AND `bundle_products`.`bundle_id` IN ("+placeholders(len(chunk))+")",
			int64Args(chunk)...)
		if err != nil {
			return nil, err
		}
		for _, id := range bundled {
			excluded[id] = true
		}
	}
	return excluded, nil
}

// recommendedTaxonomyIDs is DiscoverService#product_infos' taxonomy ids: the alive, unarchived
// products in order, without those rated_as_adult?.
func (h *handler) recommendedTaxonomyIDs(ctx context.Context, related []int64) ([]int64, error) {
	type candidate struct {
		flags             int64
		taxonomyID        sql.NullInt64
		name, description sql.NullString
		sellerID          sql.NullInt64
		seller            user
		bio               sql.NullString
	}
	candidates := map[int64]*candidate{}
	err := scanNamed(ctx, h.c.DB, func(cols map[string]any) func() {
		var id int64
		c := &candidate{}
		cols["id"], cols["flags"], cols["taxonomy_id"], cols["name"], cols["description"] = &id, &c.flags, &c.taxonomyID, &c.name, &c.description
		cols["seller_id"], cols["seller_flags"], cols["seller_name"] = &c.sellerID, &c.seller.flags, &c.seller.name
		cols["username"], cols["external_id"], cols["bio"] = &c.seller.username, &c.seller.externalID, &c.bio
		return func() { candidates[id] = c }
	}, "SELECT `links`.`id`, `links`.`flags`, `links`.`taxonomy_id`, `links`.`name`, `links`.`description`,"+
		" `users`.`id` AS seller_id, COALESCE(`users`.`flags`, 0) AS seller_flags, `users`.`name` AS seller_name, `users`.`username`,"+
		" `users`.`external_id`, `users`.`bio` FROM `links` LEFT OUTER JOIN `users` ON `users`.`id` = `links`.`user_id`"+
		" WHERE `links`.`id` IN ("+placeholders(len(related))+") AND `links`.`purchase_disabled_at` IS NULL"+
		" AND `links`.`banned_at` IS NULL AND `links`.`deleted_at` IS NULL AND (`links`.`flags` & ? = 0)",
		append(int64Args(related), productArchived)...)
	if err != nil {
		return nil, err
	}
	adultSellers := map[int64]bool{}
	var taxonomyIDs []int64
	for _, id := range related {
		c := candidates[id]
		switch {
		case c == nil || c.flags&productIsAdult != 0:
			continue
		case !c.sellerID.Valid:
			// rated_as_adult? calls all_adult_products? on a nil user.
			return nil, errors.New("recommended product without a seller")
		case !c.taxonomyID.Valid:
			// Kept or not, it adds no taxonomy.
			continue
		}
		adult, seen := adultSellers[c.sellerID.Int64]
		if !seen {
			adult = c.seller.is(userAllAdultProducts) ||
				slices.ContainsFunc([]string{c.seller.name.String, sellerUsername(&c.seller), c.bio.String}, adultText)
			adultSellers[c.sellerID.Int64] = adult
		}
		if !adult && !adultText(c.name.String) && !adultText(c.description.String) {
			taxonomyIDs = append(taxonomyIDs, c.taxonomyID.Int64)
		}
	}
	return taxonomyIDs, nil
}

// union is Array#|.
func union(a, b []int64) []int64 {
	out := make([]int64, 0, len(a)+len(b))
	seen := make(map[int64]bool, len(a)+len(b))
	for _, v := range slices.Concat(a, b) {
		if !seen[v] {
			seen[v] = true
			out = append(out, v)
		}
	}
	return out
}
