package products

import (
	"context"

	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// cardOffers sets each card's effective_default_offer_code from what ProductPresenter::Card
// preloads: its default_offer_code and the seller's auto_apply_offer_code.
func (h *handler) cardOffers(p *page, cards []*card) error {
	if len(cards) == 0 {
		return nil
	}
	ctx := p.Ctx
	// Only the auto code's own columns hold for every card; which cards it leaves out is read here.
	auto, err := h.sellerAutoApply(p, cards[0].prod)
	if err != nil {
		return err
	}
	var excluded map[int64]bool
	if auto != nil && auto.anyExcluded {
		if excluded, err = h.excludedCards(ctx, auto.id, cards); err != nil {
			return err
		}
	}
	var ids []int64
	for _, c := range cards {
		if id := c.prod.defaultOfferCodeID; id.Valid {
			ids = append(ids, id.Int64)
		}
	}
	defaults, err := h.offerCodesByID(ctx, ids)
	if err != nil {
		return err
	}
	for _, c := range cards {
		// auto_apply_offer_code_for.
		var sale *offerCode
		if auto != nil && rails.Present(auto.code.String) && auto.applicableTo(c.prod, excluded[c.prod.id]) {
			sale = auto
		}
		code, err := h.effectiveDefault(p, c.prod, defaults[c.prod.defaultOfferCodeID.Int64], sale)
		if err != nil {
			return err
		}
		// A product's default code can be the seller's sale itself.
		c.offer, c.onSale = code, code != nil && sale != nil && code.id == sale.id
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
func (h *handler) cardPriceCents(p *page, c *card, base int64) (int64, error) {
	code, prod := c.offer, c.prod
	if code == nil || code.deletedAt.Valid || code.inactive(p.Req.Now) || code.existingOnly || code.newOnly || !code.currencyValid(prod) ||
		code.minimumQuantity.Int64 > 1 || code.minimumAmountCents.Int64 > base {
		return base, nil
	}
	if left, err := h.defaultUsesLeft(p, code); err != nil || !left {
		return base, err
	}
	if code.hasVariants {
		if covers, err := h.coversLowestPricedOption(p, c, code); err != nil || !covers {
			return base, err
		}
	}
	return max(base-code.amountOff(base), 0), nil
}

// coversLowestPricedOption is discounts_lowest_priced_option?: whether the code limits none of
// the card's options or covers one of the cheapest of its preloaded_options, whose minimum
// difference minVariantDifference holds.
func (h *handler) coversLowestPricedOption(p *page, c *card, code *offerCode) (bool, error) {
	// restricted_variants_for counts a Variant in a deleted category, and a deleted option, as the
	// product's; only an alive one can be among the cheapest. With no difference at all the
	// minimum is nil, which an option without one equals.
	var restricted, cheapest int
	err := h.c.DB.QueryRowContext(p.Ctx, "SELECT COUNT(*), COALESCE(SUM(base_variants.deleted_at IS NULL"+
		" AND (base_variants.type = 'Sku' OR variant_categories.deleted_at IS NULL)"+
		" AND base_variants.price_difference_cents <=> ?), 0) FROM offer_codes_variants"+
		" INNER JOIN base_variants ON base_variants.id = offer_codes_variants.variant_id"+
		" LEFT JOIN variant_categories ON variant_categories.id = base_variants.variant_category_id"+
		" WHERE offer_codes_variants.offer_code_id = ?"+
		" AND IF(base_variants.type = 'Variant', variant_categories.link_id, base_variants.link_id) = ?",
		c.minVariantDifference, code.id, c.prod.id).Scan(&restricted, &cheapest)
	switch {
	case err != nil || restricted == 0:
		return err == nil, err
	case c.prod.is(productIsTieredMembership):
		// lowest_priced_tier_ids weighs the tiers' prices.
		return false, fallback("catalog offer code tiers")
	}
	return cheapest > 0, nil
}
