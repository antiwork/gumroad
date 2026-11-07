package products

import (
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
	// inFlight's ? is the SCA cutoff.
	inFlight = "(purchases.created_at >= ? OR purchases.stripe_status IS NOT NULL OR purchases.processor_setup_intent_id IS NOT NULL" +
		" OR processor_payment_intents.id IS NOT NULL)"
)

var (
	notArchivedOrCommission = fmt.Sprintf("(purchases.flags & %d) = 0 AND (purchases.flags & %d) = 0",
		purchaseIsArchivedOriginalSubscription, purchaseIsCommissionCompletion)
	// countsTowardsUses is Purchase.counts_towards_offer_code_uses.
	countsTowardsUses = nonGiftSuccessStates + " AND " + notRecurringCharge + " AND " + notArchivedOrCommission
	// completedAllocations is Purchase.completed_once_per_cart_allocation_uses, without its join.
	completedAllocations = fmt.Sprintf("%s AND (purchases.flags & %d) = 0 AND purchase_offer_code_discounts.once_per_cart = TRUE"+
		" AND purchase_offer_code_discounts.once_per_cart_allocation_id IS NOT NULL AND %s",
		nonGiftSuccessStates, purchaseIsArchivedOriginalSubscription, notOwnPurchase)
	// reservations is Purchase.active_once_per_cart_offer_code_reservations, without its joins.
	reservations = fmt.Sprintf("purchases.purchase_state = 'in_progress' AND %s AND (purchases.flags & %d) = 0 AND (purchases.flags & %d) = 0"+
		" AND %s AND purchase_offer_code_discounts.once_per_cart = TRUE AND %s AND (purchases.preorder_id IS NULL OR purchases.flags & %d != 0)"+
		" AND %s", notRecurringCharge, purchaseIsAdditionalContribution, purchaseIsGiftReceiver, notArchivedOrCommission, notOwnPurchase,
		purchaseIsPreorderAuthorization, inFlight)
	// activeAllocations is Purchase.active_once_per_cart_allocation_uses, without its joins.
	activeAllocations = "purchases.purchase_state = 'in_progress' AND purchase_offer_code_discounts.once_per_cart = TRUE" +
		" AND purchase_offer_code_discounts.once_per_cart_allocation_id IS NOT NULL AND " + notOwnPurchase + " AND " + inFlight
)

// codeQuantityLeft is OfferCode#quantity_left: max_purchase_count less times_used and the
// once-per-cart uses still in flight, read once per page.
func (h *handler) codeQuantityLeft(p *page, c *offerCode) (int64, error) {
	if left, ok := p.codesLeft[c.id]; ok {
		return left, nil
	}
	cutoff := p.Req.Now.Add(-timeToCompleteSCA)
	var perItem, legacyPerCart, allocations, legacyReserved, allocationsReserved int64
	err := h.c.DB.QueryRowContext(p.Ctx, "SELECT"+
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
	if err != nil {
		return 0, err
	}
	left := c.maxPurchaseCount.Int64 - perItem - legacyPerCart - allocations - legacyReserved - allocationsReserved
	if p.codesLeft == nil {
		p.codesLeft = map[int64]int64{}
	}
	p.codesLeft[c.id] = left
	return left, nil
}

// defaultUsesLeft is default_offer_code_uses_left?: is_valid_for_purchase? at a quantity of one.
func (h *handler) defaultUsesLeft(p *page, c *offerCode) (bool, error) {
	if !c.maxPurchaseCount.Valid {
		return true, nil
	}
	left, err := h.codeQuantityLeft(p, c)
	return left >= 1, err
}

// effectiveDefault is effective_default_offer_code, uses left and all.
func (h *handler) effectiveDefault(p *page, prod *product, explicit, auto *offerCode) (*offerCode, error) {
	code, capped := effectiveDefaultCode(prod, explicit, auto, p.Req.Now)
	if !capped {
		return code, nil
	}
	if left, err := h.defaultUsesLeft(p, code); err != nil || left {
		return code, err
	}
	return auto, nil
}

// usesShortfall is the error_code has_sufficient_times_of_use? gives at the code's usage units;
// "" when there are uses enough.
func (h *handler) usesShortfall(p *page, c *offerCode) (string, error) {
	if !c.maxPurchaseCount.Valid {
		return "", nil
	}
	left, err := h.codeQuantityLeft(p, c)
	switch {
	case err != nil:
		return "", err
	case left >= c.usageUnits(p.quantity()):
		return "", nil
	case left > 0:
		return "insufficient_times_of_use", nil
	}
	return "sold_out", nil
}
