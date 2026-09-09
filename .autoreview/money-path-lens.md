# Domain lens: refund fee-retention recovery (money path)

This PR keeps buyer refunds durable when Stripe fee-retention (payout-transfer reversal or
account debit) fails, then retries collection hourly. Review as a money-moving repair, not a
bookkeeping convenience. Numbered checks:

1. **Idempotency / double collection.** Run refund + recovery twice, or lose the Stripe response
   after success. Does a second reversal or grouped account debit move money again? Name the
   idempotency key, the list/page-before-create path, and what happens after the key window
   expires. `lock: :until_executed` is not processor exactly-once.

2. **Whose money, which currency.** For every amount written (`fee_retention_collected_cents`,
   Credit, BalanceTransaction, holding-currency adjustment), find where it is computed and whose
   pocket it is. US Gumroad-managed vs EU connected vs retired settlement currency must not share
   a polarity by identifier symmetry. Zero-USD holding-currency adjustments must not hide a real
   second debit.

3. **Raise vs side effect order.** Locate each Stripe call and each local persist. A raise after
   a successful reversal/debit plus Sidekiq retry without a stable key is duplicate money. A
   local rollback after Stripe already refunded the buyer is the original bug — confirm it cannot
   recur on any remaining path, including combined-charge transactions.

4. **Pending is not success.** `fee_retention_pending` must not clear because a reversal ID exists.
   Settlement lookup must be resumable independently of collection. Pending may clear only after
   collected cents are recorded or an explicit terminal disposition. Count already-collected
   money before any terminal clear.

5. **Per-row isolation and scan completeness.** One row's Stripe/DB error must not abort later
   rows. The candidate query must not strand older pending recoveries (no age cutoff as a fake
   index). An unindexed JSON predicate that cannot be proven cheap is a merge blocker, not a
   follow-up, if production recovery would run this job.

6. **Vacuous specs.** Reverting the production guard should redden a named example. Stubbing
   `transfer_group` so VCR stays green must not skip the live collection path. Assert collected
   cents / no second Transfer.create, not only that ErrorNotifier fired.

7. **External money calls outside DB transactions.** Recovery must not hold a row lock across a
   Stripe round trip. Missing Credits are logged, not recreated into a double ledger.

8. **Ineffective / balance-reversed refunds.** Terminally resolve pending work without collecting
   another fee; account for already-collected money first.
