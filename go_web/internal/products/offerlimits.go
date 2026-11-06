package products

import (
	"context"
	"fmt"
	"time"
)

// timeToCompleteSCA is ChargeProcessor::TIME_TO_COMPLETE_SCA, how long an unconfirmed
// once-per-cart attempt holds its use.
const timeToCompleteSCA = 15 * time.Minute

const (
	nonGiftSuccessStates = "purchases.purchase_state IN ('preorder_authorization_successful', 'successful', 'not_charged')"
	discountJoin         = " INNER JOIN purchase_offer_code_discounts ON purchase_offer_code_discounts.purchase_id = purchases.id"
	intentJoin           = " LEFT OUTER JOIN processor_payment_intents ON processor_payment_intents.purchase_id = purchases.id"
	notOwnPurchase       = "(purchases.purchaser_id IS NULL OR purchases.purchaser_id != purchases.seller_id)"
	// inFlight takes the SCA cutoff.
	inFlight = "(purchases.created_at >= ? OR purchases.stripe_status IS NOT NULL OR purchases.processor_setup_intent_id IS NOT NULL" +
		" OR processor_payment_intents.id IS NOT NULL)"
)

var (
	notArchivedOrCommission = fmt.Sprintf("(purchases.flags & %d) = 0 AND (purchases.flags & %d) = 0",
		purchaseIsArchivedOriginalSubscription, purchaseIsCommissionCompletion)
	// countsTowardsUses is Purchase.counts_towards_offer_code_uses.
	countsTowardsUses = nonGiftSuccessStates + " AND " + notRecurringCharge + " AND " + notArchivedOrCommission
	// completedAllocations is Purchase.completed_once_per_cart_allocation_uses, past its join.
	completedAllocations = fmt.Sprintf("%s AND (purchases.flags & %d) = 0 AND purchase_offer_code_discounts.once_per_cart = TRUE"+
		" AND purchase_offer_code_discounts.once_per_cart_allocation_id IS NOT NULL AND %s",
		nonGiftSuccessStates, purchaseIsArchivedOriginalSubscription, notOwnPurchase)
	// reservations is Purchase.active_once_per_cart_offer_code_reservations, past its joins.
	reservations = fmt.Sprintf("purchases.purchase_state = 'in_progress' AND %s AND (purchases.flags & %d) = 0 AND (purchases.flags & %d) = 0"+
		" AND %s AND purchase_offer_code_discounts.once_per_cart = TRUE AND %s AND (purchases.preorder_id IS NULL OR purchases.flags & %d != 0)"+
		" AND %s", notRecurringCharge, purchaseIsAdditionalContribution, purchaseIsGiftReceiver, notArchivedOrCommission, notOwnPurchase,
		purchaseIsPreorderAuthorization, inFlight)
	// activeAllocations is Purchase.active_once_per_cart_allocation_uses, past its joins.
	activeAllocations = "purchases.purchase_state = 'in_progress' AND purchase_offer_code_discounts.once_per_cart = TRUE" +
		" AND purchase_offer_code_discounts.once_per_cart_allocation_id IS NOT NULL AND " + notOwnPurchase + " AND " + inFlight
)

// quantityLeft is OfferCode#quantity_left: max_purchase_count less times_used and the
// once-per-cart uses still in flight at now.
func (h *handler) quantityLeft(ctx context.Context, c *offerCode, now time.Time) (int64, error) {
	cutoff := now.Add(-timeToCompleteSCA)
	var perItem, legacyPerCart, allocations, legacyReserved, allocationsReserved int64
	err := h.c.DB.QueryRowContext(ctx, "SELECT"+
		" (SELECT COALESCE(SUM(purchases.quantity), 0) FROM purchases LEFT OUTER JOIN purchase_offer_code_discounts"+
		" ON purchase_offer_code_discounts.purchase_id = purchases.id WHERE purchases.offer_code_id = ? AND "+countsTowardsUses+
		" AND (purchase_offer_code_discounts.once_per_cart = FALSE OR purchase_offer_code_discounts.once_per_cart IS NULL)),"+
		" (SELECT COUNT(*) FROM purchases"+discountJoin+" WHERE purchases.offer_code_id = ? AND "+countsTowardsUses+
		" AND purchase_offer_code_discounts.once_per_cart = TRUE AND purchase_offer_code_discounts.once_per_cart_allocation_id IS NULL),"+
		" (SELECT COUNT(DISTINCT purchase_offer_code_discounts.once_per_cart_allocation_id) FROM purchases"+discountJoin+
		" WHERE purchases.offer_code_id = ? AND "+completedAllocations+"),"+
		" (SELECT COUNT(*) FROM purchases"+discountJoin+intentJoin+" WHERE purchases.offer_code_id = ? AND "+reservations+
		" AND purchase_offer_code_discounts.once_per_cart_allocation_id IS NULL),"+
		" (SELECT COUNT(DISTINCT purchase_offer_code_discounts.once_per_cart_allocation_id) FROM purchases"+discountJoin+intentJoin+
		" WHERE purchases.offer_code_id = ? AND "+activeAllocations+" AND purchase_offer_code_discounts.once_per_cart_allocation_id NOT IN"+
		" (SELECT purchase_offer_code_discounts.once_per_cart_allocation_id FROM purchases"+discountJoin+
		" WHERE purchases.offer_code_id = ? AND "+completedAllocations+"))",
		c.id, c.id, c.id, c.id, cutoff, c.id, cutoff, c.id).
		Scan(&perItem, &legacyPerCart, &allocations, &legacyReserved, &allocationsReserved)
	return c.maxPurchaseCount.Int64 - perItem - legacyPerCart - allocations - legacyReserved - allocationsReserved, err
}

// defaultUsesLeft is default_offer_code_uses_left?, which Current memoizes per request.
func (h *handler) defaultUsesLeft(p *page, c *offerCode) (bool, error) {
	if !c.maxPurchaseCount.Valid {
		return true, nil
	}
	if left, ok := p.usesLeft[c.id]; ok {
		return left, nil
	}
	n, err := h.quantityLeft(p.Ctx, c, p.Req.Now)
	if err != nil {
		return false, err
	}
	if p.usesLeft == nil {
		p.usesLeft = map[int64]bool{}
	}
	// is_valid_for_purchase? at a quantity of one.
	p.usesLeft[c.id] = n >= 1
	return n >= 1, nil
}

// effectiveDefault is effective_default_offer_code, uses left and all.
func (h *handler) effectiveDefault(p *page, prod *product, explicit, auto *offerCode) (*offerCode, error) {
	code, limited := effectiveDefaultCode(prod, explicit, auto, p.Req.Now)
	if !limited {
		return code, nil
	}
	if left, err := h.defaultUsesLeft(p, code); err != nil || left {
		return code, err
	}
	return auto, nil
}

// sufficientUses is has_sufficient_times_of_use? for one item, the quantity raised to the
// code's minimum, else the error_code its shortfall gives.
func (h *handler) sufficientUses(ctx context.Context, c *offerCode, now time.Time) (string, error) {
	if !c.maxPurchaseCount.Valid {
		return "", nil
	}
	left, err := h.quantityLeft(ctx, c, now)
	switch {
	case err != nil:
		return "", err
	case left >= max(1, c.minimumQuantity.Int64):
		return "", nil
	case left > 0:
		return "insufficient_times_of_use", nil
	}
	return "sold_out", nil
}
