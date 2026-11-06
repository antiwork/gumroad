package products

import (
	"database/sql"
	"testing"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/session/testdb"
)

// OfferCode#quantity_left: what counts as a use, and which once-per-cart attempts still hold one.
func TestQuantityLeftCountsUsesAndReservations(t *testing.T) {
	const codeID = int64(1_798_001)
	now := testNow.Add(time.Hour)
	use := func(t *testing.T, conn *sql.DB, id int64, columns map[string]any) {
		insertCodeUse(t, conn, id, codeID, columns)
	}
	// perCart gives purchase id a once-per-cart discount row, in allocation (nil for a legacy one).
	perCart := func(t *testing.T, conn *sql.DB, id int64, allocation any) {
		testdb.Insert(t, conn, "purchase_offer_code_discounts", map[string]any{"id": id, "purchase_id": id, "offer_code_id": codeID,
			"offer_code_amount": 100, "pre_discount_minimum_price_cents": 0, "once_per_cart": true, "once_per_cart_allocation_id": allocation,
			"created_at": testNow, "updated_at": testNow})
	}
	attempt := func(minutesAgo int) map[string]any {
		return map[string]any{"purchase_state": "in_progress", "created_at": now.Add(-time.Duration(minutesAgo) * time.Minute)}
	}
	for _, c := range []struct {
		name  string
		used  int64
		setup func(t *testing.T, conn *sql.DB)
	}{
		{name: "a use", used: 1, setup: func(t *testing.T, conn *sql.DB) { use(t, conn, 1_798_101, nil) }},
		{name: "a use of several", used: 3, setup: func(t *testing.T, conn *sql.DB) { use(t, conn, 1_798_101, map[string]any{"quantity": 3}) }},
		{name: "a renewal", setup: func(t *testing.T, conn *sql.DB) {
			use(t, conn, 1_798_101, map[string]any{"subscription_id": 1_798_901})
		}},
		{name: "an original subscription purchase", used: 1, setup: func(t *testing.T, conn *sql.DB) {
			use(t, conn, 1_798_101, map[string]any{"subscription_id": 1_798_901, "flags": purchaseIsOriginalSubscription})
		}},
		{name: "a failed purchase", setup: func(t *testing.T, conn *sql.DB) { use(t, conn, 1_798_101, map[string]any{"purchase_state": "failed"}) }},
		{name: "a gift's receiver", setup: func(t *testing.T, conn *sql.DB) {
			use(t, conn, 1_798_101, map[string]any{"purchase_state": "gift_receiver_purchase_successful"})
		}},
		{name: "an archived original subscription", setup: func(t *testing.T, conn *sql.DB) {
			use(t, conn, 1_798_101, map[string]any{"flags": purchaseIsArchivedOriginalSubscription})
		}},
		{name: "a commission's completion", setup: func(t *testing.T, conn *sql.DB) {
			use(t, conn, 1_798_101, map[string]any{"flags": purchaseIsCommissionCompletion})
		}},
		// A once-per-cart use counts once, whatever its quantity.
		{name: "a legacy once-per-cart use", used: 1, setup: func(t *testing.T, conn *sql.DB) {
			use(t, conn, 1_798_101, map[string]any{"quantity": 3})
			perCart(t, conn, 1_798_101, nil)
		}},
		{name: "two purchases of one cart", used: 1, setup: func(t *testing.T, conn *sql.DB) {
			for _, id := range []int64{1_798_101, 1_798_102} {
				use(t, conn, id, map[string]any{"purchaser_id": nil})
				perCart(t, conn, id, "cart-1")
			}
		}},
		{name: "the seller's own cart", setup: func(t *testing.T, conn *sql.DB) {
			use(t, conn, 1_798_101, map[string]any{"purchaser_id": sellerID})
			perCart(t, conn, 1_798_101, "cart-1")
		}},
		{name: "a recent legacy attempt", used: 1, setup: func(t *testing.T, conn *sql.DB) {
			use(t, conn, 1_798_101, attempt(5))
			perCart(t, conn, 1_798_101, nil)
		}},
		{name: "an abandoned legacy attempt", setup: func(t *testing.T, conn *sql.DB) {
			use(t, conn, 1_798_101, attempt(20))
			perCart(t, conn, 1_798_101, nil)
		}},
		// A payment intent can still settle after the SCA lease.
		{name: "an old attempt with a payment intent", used: 1, setup: func(t *testing.T, conn *sql.DB) {
			use(t, conn, 1_798_101, attempt(20))
			perCart(t, conn, 1_798_101, nil)
			testdb.Insert(t, conn, "processor_payment_intents", map[string]any{"id": int64(1_798_701), "purchase_id": int64(1_798_101),
				"intent_id": "pi_1", "created_at": testNow, "updated_at": testNow})
		}},
		{name: "a recent cart attempt", used: 1, setup: func(t *testing.T, conn *sql.DB) {
			use(t, conn, 1_798_101, attempt(5))
			perCart(t, conn, 1_798_101, "cart-2")
		}},
		// An attempt in a cart that completed doesn't count it twice.
		{name: "a cart attempt beside its completed purchase", used: 1, setup: func(t *testing.T, conn *sql.DB) {
			use(t, conn, 1_798_101, attempt(5))
			perCart(t, conn, 1_798_101, "cart-3")
			use(t, conn, 1_798_102, nil)
			perCart(t, conn, 1_798_102, "cart-3")
		}},
		{name: "a preorder's charge attempt", setup: func(t *testing.T, conn *sql.DB) {
			use(t, conn, 1_798_101, map[string]any{"purchase_state": "in_progress", "created_at": now, "preorder_id": 1_798_801})
			perCart(t, conn, 1_798_101, nil)
		}},
	} {
		t.Run(c.name, func(t *testing.T) {
			e := newTestEnv(t)
			conn := testdb.Open(t)
			insertOfferCode(t, conn, codeID, map[string]any{"code": "LIMITED", "amount_cents": 100, "universal": true, "max_purchase_count": 10})
			if c.setup != nil {
				c.setup(t, conn)
			}
			h := &handler{c: e.config}
			left, err := h.quantityLeft(t.Context(), &offerCode{id: codeID, maxPurchaseCount: sql.NullInt64{Int64: 10, Valid: true}}, now)
			if err != nil || left != 10-c.used {
				t.Errorf("%d left, %v; want %d", left, err, 10-c.used)
			}
		})
	}
}
