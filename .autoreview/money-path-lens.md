Money/risk panel for antiwork/gumroad#7368 at 7a2d7539ca0036e76d1b5ad8fae9daf860052019.
Review the three-dot diff origin/main...HEAD. Do not run tests. Do not modify files.

Claim: seller-held Stripe charges with missing settlement data defer (in_progress + charge data saved + receipt/content withheld + finalization job) instead of failing or synthesizing USD. Gumroad-held non-presentment nil flow keeps the USD fallback. Buyer-presentment deferral stays. Non-Stripe USD fallback stays.

THIS HEAD vs prior panel at 826adeb703 (3 P1s). Re-grade each as RESOLVED / STILL-OPEN / REGRESSED with file:line:
- P1-A: Do not treat a known Gumroad-held charge as unknown ownership. purchase.merchant_account nil + charge.merchant_account present and Gumroad-owned (user_id nil) is known ownership; processor_settlement_deferrable? and load_flow_of_funds must not defer / must still mint USD.
- P1-B: Include unknown ownership in the checkout deferral gate (charge_intent_waiting_for_flow_of_funds? / charge_settlement_deferrable?).
- P1-C: Allow the finalizer to poll explicitly deferrable unknown-account charges.

New since 826adeb703: charge_settlement_deferrable?; load_flow_of_funds unknown_stripe_ownership also fires when charge.merchant_account.nil?; processor_settlement_deferrable? ORs charge.merchant_account.nil?; finalizer early-return matches.

Numbered checks. Verdict READY-TO-MERGE or CHANGES-REQUIRED. P1 merge-blocking / P2 should-fix. Only report accepted/actionable findings at P1 or P0.

1. NIL / SPLIT MERCHANT ACCOUNT. Can a charged seller-held row still reach load_flow_of_funds / MarkSuccessfulService / success with a synthetic USD flow? Cover the split: purchase.merchant_account nil but charge.merchant_account present (Gumroad-owned vs seller-owned). Cover save_charge_data, SCA, sync, finalization jobs.

2. PREDICATE PARITY. processor_settlement_deferrable?, pending_processor_settlement?, charge_settlement_deferrable?, FinalizeBuyerPresentmentChargeJob early return, and save_charge_data(..., allow_missing_flow_of_funds:) must describe the SAME set. Name any charge one gate treats as deferrable and another does not (PayPal, Braintree, Stripe custom vs destination, Indian merchant, charge without merchant_account, standalone vs combined, purchase account present + charge account nil).

3. GUMROAD-HELD UNCHANGED. Present Gumroad merchant account + no presentment still synthesizes USD. Non-Stripe still synthesizes. A mutant applying seller-held nil path to Gumroad-held money must be catchable. Fail-closed unknown ownership must not swallow known Gumroad-held when only the purchase association is blank.

4. SIBLING PATH. Root cause without naming a surface: a charged purchase whose processor has not produced settlement data must not book balances or synthesize the account currency. Enumerate remaining success/mark-successful/load_flow_of_funds callers.

5. COMBINED-CHARGE. Can one purchase finalize and send a receipt while siblings are still in_progress? Is build_flow_of_funds_from_combined_charge nil-safe when some siblings already have a flow?

6. RECURRING. Sync widened buyer_presentment? && is_recurring_subscription_charge to just is_recurring_subscription_charge then handle_purchase_success. Intended for Gumroad-held recurring with a flow? Can it grant access before settlement?

7. INVERSE OPS. Between enqueue and FinalizeBuyerPresentment*Job: refund, chargeback, cancel, mark_failed. Does the job re-check eligibility?

8. RECEIPT EXACTLY-ONCE for seller-held combined charges. If the job returns early, is a charged in_progress purchase stranded? lock: :until_executed with no TTL — can a crash mute later enqueues?

9. SPECS LOAD-BEARING. Which example fails if (a) seller-held gating dropped from ChargeService, (b) from processor_settlement_deferrable?, (c) from finalize charge job, (d) unknown_stripe_ownership dropped from USD mint, (e) merchant_account.nil? / charge.merchant_account.nil? dropped from deferrable?, (f) subscription handle_purchase_success widening reverted?

End with exactly one line: VERDICT: clean   or   VERDICT: findings
