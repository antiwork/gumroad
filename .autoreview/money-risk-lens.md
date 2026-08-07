# Money/risk review lens: PayPal price-integrity guard

This diff touches the PayPal charge processor's order-update and capture-confirmation paths
(app/business/payments/charging/implementations/paypal/paypal_charge_processor.rb). Apply the
autoreview skill's "widening/loosening an eligibility predicate" and general money-path lenses.
Adversarial checklist:

1. Does `update_order_from_product_info`'s new guard compare currency AND value correctly for
   every currency pairing PayPal supports (zero-decimal currencies, rounding)? Check the exact
   comparison operator (>= vs >) and BigDecimal precision.
2. Enumerate every caller of `update_order_from_product_info` and `ensure_captured_amount_matches!`
   — does the guard apply on every code path that can lower a PayPal order total, or only the one
   the PR's spec exercises?
3. Fail-closed correctness: when PayPal's current total/currency is unreadable or non-numeric,
   does the code raise BEFORE any mutating call, and does the controller's rescue turn that into
   `success: false` without leaking a 500 or silently succeeding?
4. Capture-amount-mismatch handling: when `ensure_captured_amount_matches!` raises after PayPal
   has already captured funds, is there a compensating action (refund/void) or does Gumroad's
   ledger diverge from what PayPal actually charged (money captured but purchase not marked
   successful, or vice versa)?
5. Race/idempotency: could the guard be bypassed by concurrent requests re-using a stale current
   total read before another request's update landed?
6. Are the new specs load-bearing (mutate the guard's comparison and confirm the new example
   reddens), and is a non-numeric-current-total example present per the reviewer's own PR body
   claim?
7. Currency-change handling: does blocking a currency change on update also apply correctly when
   PayPal's total is expressed in a different currency's minor unit convention?
