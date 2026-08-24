# Money/risk panel lens — gumroad#7368 seller-held settlement deferral

Review the three-dot branch diff against the stated base. This is a money-path change:
seller-held Stripe purchases with missing settlement data should defer, not fail or
synthesize USD. Gumroad-held non-presentment nil flow keeps the USD fallback.

PRIOR REVIEW (same tree; HEAD `de20a588` is an empty CI-trigger commit on top of
`952ec32470`) reported this as STILL-OPEN — re-grade it against the live code, do not
rubber-stamp or dismiss it without a file:line reason:

- [P1] `Purchase#funds_held_by_gumroad?` treats `merchant_account == nil` as Gumroad-held,
  so `load_flow_of_funds` synthesizes USD. Sync calls `prepare_merchant_account` AFTER the
  missing-flow deferral branch. A seller-held Stripe purchase reaching sync without the
  association loaded/persisted can receive the fabricated USD flow this patch exists to
  prevent. Confirm reachability: can a charged seller-held row actually arrive at
  `load_flow_of_funds` / `processor_settlement_deferrable?` with nil merchant_account?

Numbered checks (answer each with file:line). Verdict READY-TO-MERGE or CHANGES-REQUIRED.
P1 merge-blocking / P2 should-fix. Do not invent P3 unless it is a money-safety comment lie.

1. PREDICATE PARITY. `processor_settlement_deferrable?`, `pending_processor_settlement?`,
   `charge_intent_waiting_for_flow_of_funds?`, FinalizeBuyerPresentmentChargeJob early
   return, and `save_charge_data(..., allow_missing_flow_of_funds:)` must describe the SAME
   set. Name any charge one gate treats as deferrable and another does not.

2. NIL MERCHANT ACCOUNT. `funds_held_by_gumroad?` is
   `!(stripe_charge_processor? && merchant_account&.user_id.present?)`. What happens when
   merchant_account is nil at save_charge_data / load_flow_of_funds / sync time? Is
   prepare-before-decide required, or is nil unreachable for seller-held charged rows?

3. SIBLING PATH. Root cause without naming a surface: a charged purchase whose processor
   has not produced settlement data must not book balances or synthesize the account
   currency. Enumerate remaining success/mark-successful/load_flow_of_funds callers.

4. COMBINED-CHARGE. Seller-held combined charges can have many purchases. Can one
   finalize and send a receipt while siblings are still in_progress?

5. RECURRING SUBSCRIPTION WIDENING. Sync now uses `is_recurring_subscription_charge`
   alone (not also `buyer_presentment?`). Can handle_purchase_success grant access or book
   money before settlement?

6. INVERSE OPS. Between enqueue and FinalizeBuyerPresentment*Job: refund, chargeback,
   cancel, mark_failed. Does the job re-check eligibility?

7. USD FALLBACK STILL LIVE for Gumroad-held non-presentment. Confirm a seller-held row
   can no longer receive a synthesized USD flow on every path that calls load_flow_of_funds.

8. RECEIPT / CONTENT. Exactly-once send for seller-held combined charges. No permanent
   withhold if charge_presentment and merchant_account.user_id are both blank.

Do not run the test suite. Do not modify files. Write the full verdict in the final message.
