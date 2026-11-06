package products

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"strconv"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/web"
)

// salesCountTTL is cached_sales_count's expires_in.
const salesCountTTL = time.Minute

// loadSalesCount is ProductPresenter.cached_sales_count: Rails.cache under a key that moves
// with each purchase row, else successful_sales_count from Elasticsearch, written back.
func (h *handler) loadSalesCount(ctx context.Context, p *page, prod *product, v *view) error {
	if !prod.is(productShouldShowSalesCount) {
		return nil
	}
	var latest sql.NullInt64
	err := h.c.DB.QueryRowContext(ctx, "SELECT `purchases`.`id` FROM `purchases` WHERE `purchases`.`link_id` = ?"+
		" ORDER BY `purchases`.`id` DESC LIMIT 1", prod.id).Scan(&latest)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	key := salesCountKey(prod.id, v.priceCents, latest)
	cached, found, err := h.readCache(ctx, key)
	switch {
	case err != nil:
		return err
	case found:
		n, ok := cached.(int64)
		if !ok {
			return fallback("cached sales count")
		}
		v.salesCount = n
		return nil
	}
	// Production names the index without ES_INDEX_SUFFIX.
	n, err := h.c.Page.Search.Count(ctx, "purchases", salesCountQuery(prod.id))
	if err != nil {
		return searchFailed(p, "sales count", err)
	}
	v.salesCount = n
	p.cacheWrites = append(p.cacheWrites, pendingWrite{key, n, salesCountTTL})
	return nil
}

// salesCountKey is cached_sales_count's key, whose cache_key is links/<id> under cache
// versioning; a nil price or no purchase interpolates as "".
func salesCountKey(productID int64, price *int64, latest sql.NullInt64) string {
	p, l := "", ""
	if price != nil {
		p = strconv.FormatInt(*price, 10)
	}
	if latest.Valid {
		l = strconv.FormatInt(latest.Int64, 10)
	}
	sum := sha256.Sum256([]byte("links/" + strconv.FormatInt(productID, 10) + "-" + p + "-" + l))
	return "product-presenter:sales-count-cache_" + hex.EncodeToString(sum[:])
}

// salesCountQuery is PurchaseSearchService's query for Purchase::ACTIVE_SALES_SEARCH_OPTIONS.
func salesCountQuery(productID int64) map[string]any {
	term := func(field string, value any) map[string]any {
		return map[string]any{"term": map[string]any{field: value}}
	}
	return map[string]any{"bool": map[string]any{
		"filter": []any{
			map[string]any{"terms": map[string]any{"product_id": []int64{productID}}},
			term("not_refunded_except_subscriptions", true),
			term("not_chargedback_or_chargedback_reversed", true),
			term("not_subscription_or_original_subscription_purchase", true),
			map[string]any{"terms": map[string]any{"purchase_state": []string{"preorder_authorization_successful", "successful", "not_charged"}}},
		},
		"must_not": []any{
			map[string]any{"exists": map[string]any{"field": "subscription_deactivated_at"}},
			term("selected_flags", "is_bundle_product_purchase"),
			term("selected_flags", "is_commission_completion_purchase"),
		},
	}}
}

// searchFailed is a search error: Rails raises, and whether it would fail too is unknowable here.
func searchFailed(p *page, what string, err error) error {
	web.Logger(p.Req.HTTP).Warn(what+" search failed", "error", err.Error())
	return fallback(what + " search")
}
