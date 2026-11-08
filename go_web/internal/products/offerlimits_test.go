package products

import (
	"database/sql"
	"testing"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/pages"
	"github.com/antiwork/gumroad/go_web/internal/rails"
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
	// attempt is an in-progress purchase started minutesAgo, with more columns.
	attempt := func(minutesAgo int, more ...any) map[string]any {
		columns := map[string]any{"purchase_state": "in_progress", "created_at": now.Add(-time.Duration(minutesAgo) * time.Minute)}
		for i := 0; i+1 < len(more); i += 2 {
			columns[more[i].(string)] = more[i+1]
		}
		return columns
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
				use(t, conn, id, nil)
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
			use(t, conn, 1_798_101, attempt(0, "preorder_id", 1_798_801))
			perCart(t, conn, 1_798_101, nil)
		}},
		{name: "a preorder's authorization attempt", used: 1, setup: func(t *testing.T, conn *sql.DB) {
			use(t, conn, 1_798_101, attempt(0, "preorder_id", 1_798_801, "flags", purchaseIsPreorderAuthorization))
			perCart(t, conn, 1_798_101, nil)
		}},
		{name: "a per-item discount row", used: 2, setup: func(t *testing.T, conn *sql.DB) {
			use(t, conn, 1_798_101, map[string]any{"quantity": 2})
			testdb.Insert(t, conn, "purchase_offer_code_discounts", map[string]any{"id": int64(1_798_101), "purchase_id": int64(1_798_101),
				"offer_code_id": codeID, "offer_code_amount": 100, "pre_discount_minimum_price_cents": 0, "once_per_cart": false,
				"created_at": testNow, "updated_at": testNow})
		}},
		{name: "an old attempt Stripe still has", used: 1, setup: func(t *testing.T, conn *sql.DB) {
			use(t, conn, 1_798_101, attempt(20, "stripe_status", "requires_action"))
			perCart(t, conn, 1_798_101, nil)
		}},
		{name: "an old attempt with a setup intent", used: 1, setup: func(t *testing.T, conn *sql.DB) {
			use(t, conn, 1_798_101, attempt(20, "processor_setup_intent_id", "seti_1"))
			perCart(t, conn, 1_798_101, nil)
		}},
		{name: "a renewal's attempt", setup: func(t *testing.T, conn *sql.DB) {
			use(t, conn, 1_798_101, attempt(5, "subscription_id", 1_798_901))
			perCart(t, conn, 1_798_101, nil)
		}},
		{name: "an additional contribution's attempt", setup: func(t *testing.T, conn *sql.DB) {
			use(t, conn, 1_798_101, attempt(5, "flags", purchaseIsAdditionalContribution))
			perCart(t, conn, 1_798_101, nil)
		}},
		{name: "the seller's own attempt", setup: func(t *testing.T, conn *sql.DB) {
			use(t, conn, 1_798_101, attempt(5, "purchaser_id", sellerID))
			perCart(t, conn, 1_798_101, nil)
		}},
		{name: "an abandoned cart attempt", setup: func(t *testing.T, conn *sql.DB) {
			use(t, conn, 1_798_101, attempt(20))
			perCart(t, conn, 1_798_101, "cart-4")
		}},
		{name: "two lines of one cart attempt", used: 1, setup: func(t *testing.T, conn *sql.DB) {
			for _, id := range []int64{1_798_101, 1_798_102} {
				use(t, conn, id, attempt(5))
				perCart(t, conn, id, "cart-5")
			}
		}},
		{name: "a cart that wasn't charged", used: 1, setup: func(t *testing.T, conn *sql.DB) {
			use(t, conn, 1_798_101, map[string]any{"purchase_state": "not_charged"})
			perCart(t, conn, 1_798_101, "cart-6")
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
			p := &page{Visit: &pages.Visit{Ctx: t.Context(), Req: &rails.Request{Now: now}}}
			left, err := h.codeQuantityLeft(p, &offerCode{id: codeID, maxPurchaseCount: sql.NullInt64{Int64: 10, Valid: true}})
			if err != nil || left != 10-c.used {
				t.Errorf("%d left, %v; want %d", left, err, 10-c.used)
			}
		})
	}
}

// Ruby 3.4's normalize_code and casecmp? on each; nothing for a code Rails reads differently.
func TestNormalizeCodeAndCasecmp(t *testing.T) {
	for code, want := range map[string]any{
		"SAVE10":        "save10",
		"CAFE\u0301":    "café",
		"Diwali\u2060":  "diwali\u2060",
		"STRAßE":        "straße",
		"\u00a0Ŀ\u00a0": "\u00a0ŀ\u00a0",
		"I\u0307":       "i\u0307",
		"\u0130":        "i\u0307",
		"Σ":             nil,
		"SAVE 10":       nil,
		"save10\u2028":  nil,
	} {
		got, ok := normalizeCode(code)
		if want == nil && ok || want != nil && (!ok || got != want) {
			t.Errorf("%+q: %+q %v, want %+q", code, got, ok, want)
		}
	}
	for _, c := range []struct {
		a, b string
		want bool
	}{{"straße", "STRASSE", true}, {"café", "CAFÉ", true}, {"café", "CAFE\u0301", false}, {"diwali\u2060", "Diwali", false}} {
		if casecmp(c.a, c.b) != c.want {
			t.Errorf("%+q casecmp? %+q: want %v", c.a, c.b, c.want)
		}
	}
}

// matching_tier_for(0) over normalized_ownership_duration_tiers.
func TestStartingTierPercent(t *testing.T) {
	for raw, want := range map[string]any{
		`[{"months":0,"amount_percentage":10},{"months":12,"amount_percentage":25}]`: int64(10),
		`[{"months":"0","amount_percentage":"15"}]`:                                  int64(15),
		`[{"amount_percentage":7.9}]`:                                                int64(7),
		`[{"months":-1,"amount_percentage":5},{"months":0,"amount_percentage":9}]`:   int64(9),
		`[{"months":0,"amount_percentage":9},{"months":0,"amount_percentage":9}]`:    int64(9),
		`[{"months":0,"amount_percentage":9},{"months":0,"amount_percentage":8}]`:    nil,
		`[{"months":12,"amount_percentage":25}]`:                                     nil,
		`[{"months":true,"amount_percentage":25}]`:                                   nil,
		`[{"months":12,"amount_percentage":25},null]`:                                nil,
		`[1]`: nil,
	} {
		got, ok := tierPercent(raw, 0)
		if want == nil && ok || want != nil && (!ok || got != want) {
			t.Errorf("%s: %d %v, want %v", raw, got, ok, want)
		}
	}
}

// matching_tier_for picks the tier the buyer's months reach, and months_since counts whole
// months in UTC, a short month's end clamping the day.
func TestTierPercentAndMonthsSince(t *testing.T) {
	tiers := `[{"months":0,"amount_percentage":10},{"months":12,"amount_percentage":25},{"months":6,"amount_percentage":15}]`
	for months, want := range map[int64]int64{0: 10, 5: 10, 6: 15, 11: 15, 12: 25, 40: 25} {
		if got, ok := tierPercent(tiers, months); !ok || got != want {
			t.Errorf("%d months: %d %v, want %d", months, got, ok, want)
		}
	}
	at := func(s string) time.Time {
		v, err := time.Parse(time.RFC3339, s)
		if err != nil {
			t.Fatal(err)
		}
		return v
	}
	for _, c := range []struct {
		from, to string
		want     int64
	}{
		{"2026-01-15T10:00:00Z", "2026-11-15T10:00:00Z", 10},
		{"2026-01-15T10:00:00Z", "2026-11-15T09:59:59Z", 9},
		{"2026-01-31T12:00:00Z", "2026-02-28T12:00:00Z", 1},
		{"2026-01-31T12:00:00Z", "2026-02-28T11:00:00Z", 0},
		{"2025-12-01T00:00:00Z", "2026-01-01T00:00:00Z", 1},
		{"2026-12-01T00:00:00Z", "2026-11-01T00:00:00Z", 0},
	} {
		if got := monthsSince(at(c.from), at(c.to)); got != c.want {
			t.Errorf("%s to %s: %d, want %d", c.from, c.to, got, c.want)
		}
	}
}

// The tier is the buyer's for this product, so it goes on a copy: the seller's cached sale also
// prices the other cards, whose discounted_price_cents reads the code's own columns.
func TestResolveDiscountLeavesTheCodeAlone(t *testing.T) {
	c := &offerCode{tiers: 2, tiersJSON: sql.NullString{String: `[{"months":0,"amount_percentage":10},{"months":12,"amount_percentage":25}]`, Valid: true}}
	got, reason := c.resolveDiscount(13)
	if reason != "" || got == c || got.amountPercentage != (sql.NullInt64{Int64: 25, Valid: true}) || c.amountPercentage.Valid {
		t.Errorf("%q: got %+v, the code %+v", reason, got, c)
	}
	plain := &offerCode{amountPercentage: sql.NullInt64{Int64: 5, Valid: true}}
	if got, reason := plain.resolveDiscount(0); reason != "" || got != plain {
		t.Errorf("an untiered code: %q %p", reason, got)
	}
}
