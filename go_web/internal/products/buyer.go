package products

import (
	"context"
	"database/sql"
	"errors"
	"fmt"

	"github.com/antiwork/gumroad/go_web/internal/db"
	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// notRecurringCharge is Purchase.not_recurring_charge.
var notRecurringCharge = fmt.Sprintf("(purchases.subscription_id IS NULL OR purchases.flags & %[1]d = %[1]d OR purchases.flags & %[2]d = %[2]d)",
	purchaseIsOriginalSubscription, purchaseIsGiftReceiver)

// qualifyingPurchases is OfferCode#qualifying_ownership_purchases.
var qualifyingPurchases = fmt.Sprintf("purchases.purchase_state IN ('preorder_authorization_successful', 'successful',"+
	" 'not_charged', 'gift_receiver_purchase_successful') AND (purchases.flags & %d) = 0 AND %s AND (purchases.flags & %d) = 0"+
	" AND (purchases.stripe_refunded IS NULL OR purchases.stripe_refunded = 0)"+
	" AND (purchases.chargeback_date IS NULL OR purchases.flags & %d != 0) AND (purchases.flags & %d) = 0",
	purchaseIsAdditionalContribution, notRecurringCharge, purchaseIsGiftSender, purchaseChargebackReversed, purchaseIsAccessRevoked)

// resolvesForBuyer is whether OfferCodeDiscountComputingService gives the code a discount for
// buyer, nil when signed out: evaluate_for_buyer, unless returning_customer?.
func (h *handler) resolvesForBuyer(ctx context.Context, prod *product, c *offerCode, buyer *signedInUser) (bool, error) {
	if buyer == nil {
		return !c.existingOnly, nil
	}
	if c.newOnly {
		if returning, err := h.returningCustomer(ctx, buyer, prod.userID); err != nil || returning {
			return false, err
		}
	}
	if !c.existingOnly {
		return true, nil
	}
	if c.hasOwnershipVariants {
		return false, fallback("offer code ownership variants")
	}
	return h.buyerOwns(ctx, buyer, c.id, prod)
}

// returningCustomer is OfferCode#returning_customer?(purchaser_ids: [buyer.id], emails: [buyer.email]).
func (h *handler) returningCustomer(ctx context.Context, buyer *signedInUser, sellerID int64) (bool, error) {
	q := "SELECT 1 FROM purchases WHERE " + qualifyingPurchases + " AND purchases.seller_id = ? AND purchases."
	found, err := h.exists(ctx, q+"purchaser_id = ? LIMIT 1", sellerID, buyer.id)
	if err != nil || found || !rails.Present(buyer.email.String) {
		return found, err
	}
	return h.exists(ctx, q+"email = ? LIMIT 1", sellerID, buyer.email.String)
}

// buyerOwns is whether ownership_months_for(buyer, ownership_reference_products(prod)) is a
// number: the code's ownership products, else prod, bought under the account or, once it's
// confirmed, its email.
func (h *handler) buyerOwns(ctx context.Context, buyer *signedInUser, codeID int64, prod *product) (bool, error) {
	rows, err := h.c.DB.QueryContext(ctx, "SELECT links.id FROM links INNER JOIN offer_codes_ownership_products j"+
		" ON links.id = j.product_id WHERE j.offer_code_id = ?", codeID)
	if err != nil {
		return false, err
	}
	defer rows.Close()
	var ids []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return false, err
		}
		ids = append(ids, id)
	}
	if err := rows.Err(); err != nil {
		return false, err
	}
	if len(ids) == 0 {
		ids = []int64{prod.id}
	}
	owner, args := "purchases.purchaser_id = ?", []any{buyer.id}
	if rails.Present(buyer.email.String) && buyer.confirmedAt.Valid {
		owner, args = owner+" OR purchases.email = ?", append(args, buyer.email.String)
	}
	var oldest db.NullTime
	err = h.c.DB.QueryRowContext(ctx, "SELECT purchases.created_at FROM purchases WHERE "+qualifyingPurchases+
		" AND purchases.link_id IN ("+placeholders(len(ids))+") AND ("+owner+") ORDER BY purchases.created_at ASC LIMIT 1",
		append(int64Args(ids), args...)...).Scan(&oldest)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	// MySQL sorts a NULL created_at first, and months_since(nil) is nil.
	return oldest.Valid, err
}
