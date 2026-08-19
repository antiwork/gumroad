# Domain lens: leftover hollow Stripe merchant rows blocking payout-setup retries

This PR changes when Settings → Payments will create a Gumroad-managed Stripe account.
Leftover alive `MerchantAccount` rows with no Stripe id and no `charge_processor_alive_at`
used to make the form report success while `create_account` skipped. The fix discards
stale hollow managed-account rows and keeps blocking live or mid-flight rows. Connect
is not a managed account.

This is a money/risk eligibility change (payout rail provisioning), not a refund-policy
change. Review as a payout-setup / merchant-registration gate.

Numbered checks:

1. **Predicate completeness.** Enumerate every `MerchantAccount` shape: hollow leftover
   (nil Stripe id, nil alive_at), mid-flight hollow (same, younger than
   `STALE_HOLLOW_ACCOUNT_AGE`), live managed (Stripe id + alive), deleted leftover,
   Stripe Connect (`is_a_stripe_connect_account?`), charge-processor-dead but still
   holding a Stripe id. For each: does `blocks_new_managed_account?` and
   `discard_stale_hollow_managed_accounts!` agree? Discarding a live or mid-flight
   row, or leaving a stale hollow row blocking, is a P0/P1.

2. **Connect short-circuit.** `create_account` has always ignored Connect. Confirm a
   live Connect row does NOT block a new managed account AND is NOT discarded. A
   Connect-as-managed false positive skips payouts; discarding Connect is irreversible.

3. **Mid-flight window.** `Stripe::Account.create` runs AFTER `user.with_lock` releases.
   The age guard is what stops a second request from discarding the in-flight row and
   calling Stripe twice. Confirm `STALE_HOLLOW_ACCOUNT_AGE` is load-bearing: deleting
   the constant / treating all hollow rows as discardable must redden a spec. An
   8-day/1-year leftover spec does not pin the 10-minute bound.

4. **Call-site sweep.** Grep every caller of `blocks_new_managed_account?`,
   `create_account`, `user_has_stripe_connect_merchant_account?`, and the payments
   controller `stripe_connect_account.blank?` gate. Does any money path still treat
   "any alive MerchantAccount" as "payouts are set up"? DISPLAY vs CHARGE/provision
   must resolve identically.

5. **Cleanup side effects.** `discard_stale_hollow_managed_accounts!` calls
   `cleanup_failed_merchant_account`. For a hollow row with no Stripe id, confirm it
   does not call `Stripe::Account.delete` on nil, and `mark_deleted!` is the only
   write. A hollow row that somehow has a Stripe id must not be discarded by this
   helper.

6. **Onetime repair service.** `CleanupWedgedStripeMerchantAccounts` must stay
   idempotent, dry-run-safe if it has that mode, and must not delete live or
   mid-flight rows. Scan-set vs discard-set must match the runtime predicate.

7. **Time-boundary specs.** Examples that pin `created_at: N.ago` vs
   `STALE_HOLLOW_ACCOUNT_AGE.ago` need `travel_to` or a literal age that sits between
   the old and new bound. A spec that derives its fixture from the same constant is
   vacuous for the constant's VALUE.

8. **Specs are load-bearing.** Name the previous-variant mutation that must redden
   each new example (Connect treated as managed; young hollow discarded; stale hollow
   still blocking; `Stripe::Account.create` still called on mid-flight). A spec that
   stays green under that mutation is vacuous.

Do NOT run the test suite. Static review only. Do not modify files. Produce
READY-TO-MERGE or CHANGES-REQUIRED with P0/P1 file:line + one-line fix.
