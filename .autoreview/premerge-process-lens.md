# Premerge process checklist (grade these explicitly, in addition to technical findings)

This PR is a money-path change (payout method / Stripe bank-account directory check) on the
settings payments page. Answer each item with a verdict and evidence:

1. **Evidence for the rendered-surface change.** The diff touches
   `app/javascript/pages/Settings/Payments/Show.tsx` (server error naming a field now flags that
   input with `aria-invalid` and scrolls to it). Does the PR carry visual proof (screenshot /
   recording) of the new behaviour on the live or preview page? Is the unit-level proof
   (`Show.test.tsx`) sufficient, or is a rendered-surface check owed before a human merges?
2. **Fail-open completeness.** Enumerate every way `BankCodeDirectoryCheck` can raise or hang that
   is NOT a `Stripe::StripeError` (e.g. a non-Stripe exception from `account_number_decrypted`,
   `routing_fields_sentence`, or a frozen/short string) and say whether the seller's save is
   blocked or 500s in that case.
3. **Blocking correctness.** Is `routing_number_rejection?` narrow enough (could a *different*
   Stripe rejection be read as a routing rejection and block a legitimate save?), and is the
   seller-facing message accurate for an 8-character miss?
4. **Race coverage.** `UpdatePayoutMethod#process` now captures `baseline_active_bank_id` before the
   probe for the bank path and returns `concurrent_payout_method_change` when it moved. Name any
   interleaving still not covered (e.g. two concurrent requests both probing, then both entering the
   lock; or `user.active_bank_account` changing without its id changing).
5. **Ownership / merge state.** The PR is a draft assigned to `gumclaw` with no labels. State the
   correct terminal state for a clean money-path PR under the ownership contract (draft vs ready,
   labels, assignee) so the handoff is not left implicit.
