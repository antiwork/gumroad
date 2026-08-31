# Domain lens: Instant Payout $100 floor drop + disable-don't-hide

This PR lowers Instant Payout's settled-balance floor from $100 to $1 (Stripe/Gumroad
held funds) and keeps a disabled Get paid control when leftover balance is still
settling. Weekly / monthly / quarterly must still require $100. Review as a money path.

1. **Whole-class floor sweep.** Enumerate every reader of the old Instant $100 gate:
   `MINIMUM_INSTANT_PAYOUT_AMOUNT_CENTS`, hardcoded `10000` / `$100` Instant copy,
   `MIN_AMOUNT_CENTS` used on an Instant path, JS `MINIMUM_INSTANT_PAYOUT_AMOUNT_CENTS`.
   For each: Instant vs weekly/monthly/quarterly, display vs charge vs skip-note.
   A leftover Instant `$100` skip note, client hide, or service error while the processor
   pays at $1 is a shown-one-rule / charged-another bug (P1). Weekly still using $100 is
   required, not a miss.

2. **Call sites, not just the constant.** Reverting the constant to `100_00` should
   redden processor + service + request specs. If only the constant changes and the
   suite stays green except the constant's own file, the call-site behavior is unpinned.

3. **Cross-language duplicate.** JS `MINIMUM_INSTANT_PAYOUT_AMOUNT_CENTS = 100` vs Ruby
   `1_00`. A JS-only revert (back to 10000) must redden a frontend/request example; a
   Ruby-only revert must redden a backend example. Name any mutation nothing catches.

4. **Settling skip vs Instant floor (payouts.rb).** The skip now compares
   `amount_payable < instant_minimum` AND `unpaid_balance >= instant_minimum`. Probe:
   (a) $60 settled / $0 unpaid — should PAY, not skip;
   (b) $0 settled / $60 unpaid — skip note, no payout;
   (c) $0 settled / $150 unpaid — skip (settling), not the old "$100 Instant min";
   (d) $0.50 settled — Stripe-floor reject, not a settling skip;
   (e) weekly path still uses `MIN_AMOUNT_CENTS`. An inverted unpaid-vs-settled
   comparison that blocks a payable leftover is P1.

5. **`unpaid_amount_cents` semantics.** Presenter adds
   `instant_payout_pipeline_unpaid_balance_cents` (Stripe/Gumroad holders only).
   Confirm PayPal-held leftovers cannot light the settling banner. Confirm
   `payable_amount_cents` is still instantly-payable settled, not total unpaid.
   A banner that uses payable (settled) as "hasn't settled yet" (or the reverse) is P1.

6. **Disable-don't-hide truth table.** Product of `payable_amount_cents >= 100` and
   `unpaid_amount_cents > 0` is four states. Both-true must not land in the first
   branch with a message the seller cannot clear. Ask for the branch order and which
   state each arm handles. Disabled Get paid with no live Instant CTA when settled
   is already >= $1 is P1.

7. **Money movement vs UI.** `InstantPayoutsService` and `StripePayoutProcessor#is_user_payable`
   (Instant type) must agree with the page. UI offering Get paid for an amount the
   processor rejects (or the reverse) is P1. Processor skip-note copy now says `$1` —
   confirm no other Instant skip still says `$100`.

8. **Reach claim.** Help center says "no $100 minimum on instant payouts: $1 or more;
   $100 still applies to weekly/monthly/quarterly." Grep `app/` `lib/` for remaining
   Instant $100 claims. Over/underclaim that an agent or seller would treat as truth
   is in scope.

9. **Irreversible payout.** Floor drop means more Instant payouts fire. Confirm the
   Instant path still has the existing Stripe Instant eligibility (US, seasoning,
   debit card) and does not widen those. Confirm amounts below Stripe's real Instant
   floor cannot enqueue a transfer. A fail-closed $1 that still calls Stripe at 50c
   is P1.

10. **Do not run the test suite.** Static review only. Verdict: READY-TO-MERGE or
    CHANGES-REQUIRED with P1/P2/P3, file:line, one-line fix. P0/P1 only unless a
    P2 is load-bearing on the money path.
