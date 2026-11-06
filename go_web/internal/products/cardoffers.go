package products

import (
	"context"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// cardOffers sets each card's effective_default_offer_code from what ProductPresenter::Card
// preloads: its default_offer_code and the seller's auto_apply_offer_code.
func (h *handler) cardOffers(p *page, cards []*card) error {
	ctx, now := p.Ctx, p.Req.Now
	var auto *offerCode
	var excluded map[int64]bool
	if p.hasAutoApplyCode && len(cards) > 0 {
		var err error
		// Loaded for the first card; which cards it leaves out is read for all of them below.
		if auto, err = h.loadOfferCode(ctx, cards[0].prod, autoApplyCodes+" ORDER BY offer_codes.id ASC LIMIT 1", p.seller.id); err != nil {
			return err
		}
		if auto != nil {
			if excluded, err = h.excludedCards(ctx, auto.id, cards); err != nil {
				return err
			}
		}
	}
	for _, c := range cards {
		// auto_apply_offer_code_for.
		var sale *offerCode
		if auto != nil && rails.Present(auto.code.String) && auto.applicableTo(c.prod, excluded[c.prod.id]) {
			sale = auto
		}
		var explicit *offerCode
		if id := c.prod.defaultOfferCodeID; id.Valid {
			var err error
			if explicit, err = h.loadOfferCode(ctx, c.prod, "offer_codes.id = ? LIMIT 1", id.Int64); err != nil {
				return err
			}
		}
		code, limited := effectiveDefaultCode(c.prod, explicit, sale, now)
		if limited {
			return fallback("catalog offer code limit")
		}
		c.offer, c.onSale = code, code != nil && code == sale
	}
	return nil
}

// excludedCards is which cards' products are among the code's excluded_products.
func (h *handler) excludedCards(ctx context.Context, codeID int64, cards []*card) (map[int64]bool, error) {
	ids := make([]int64, len(cards))
	for i, c := range cards {
		ids[i] = c.prod.id
	}
	rows, err := h.c.DB.QueryContext(ctx, "SELECT x.product_id FROM offer_codes_excluded_products x WHERE x.offer_code_id = ?"+
		" AND x.product_id IN ("+placeholders(len(ids))+")", append([]any{codeID}, int64Args(ids)...)...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[int64]bool{}
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out[id] = true
	}
	return out, rows.Err()
}

// cardPriceCents is discounted_price_cents(base) through the card's effective default code.
func cardPriceCents(c *card, base int64, now time.Time) (int64, error) {
	code, prod := c.offer, c.prod
	if code == nil || code.deletedAt.Valid || code.inactive(now) || code.existingOnly || code.newOnly || !code.currencyValid(prod) ||
		code.minimumQuantity.Int64 > 1 || code.minimumAmountCents.Int64 > base {
		return base, nil
	}
	switch {
	case code.maxPurchaseCount.Valid:
		// default_offer_code_uses_left? counts purchases.
		return 0, fallback("catalog offer code limit")
	case code.hasVariants:
		// discounts_lowest_priced_option? reads the options the code covers.
		return 0, fallback("catalog offer code variants")
	}
	return max(base-code.amountOff(base), 0), nil
}
