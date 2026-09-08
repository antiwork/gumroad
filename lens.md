Review the current full diff for concrete regressions, P1/P2 only. Money-capable offer-code search values: human review, never merge. Previous findings and dispositions:
1. Recovery suppressed by UntilExecuting reacquisition: separate nonunique RecoveryJob invokes same paced worker. Specs use actual unique server middleware and prove ordinary enqueue is rejected while recovery survives. Recovery has own exhaustion retry.
2. Hot target starvation: separate queue position and edit version: enqueue uses ZADD NX, updates hash version; acknowledgement deletes unchanged targets or rotates only processed dirty targets behind older pending work. Repeated edits of the ENTIRE target set cannot reset traversal; conditional version acknowledgements preserve concurrent edits; targeted/catalogue alternate.
3. Stale destroy snapshot: used only when destroyed?; rollback/reload/successful-save regression.
4. Failed final cooldown skipped unlock: nested ensure attempts unlock independently.
5. Deleted catalogue: alive scope, targeted deleted rows remain eligible cleanup.
6. Missing index: HEAD exists check before processing; missing alive document fully indexed rather than acknowledged empty; missing-index real test (not stubbed error).
7. Timestamp ties: existing Link#product_and_universal_offer_codes itself uses (product_codes + universal_codes).sort_by(&:created_at), no SQL order or ID tiebreak. Do NOT claim it already sorts IDs. Preserve existing semantics; frozen-time cross-source cap parity tested.
8. Sidekiq::Testing.inline! executes scheduled jobs immediately. Test-only fake! around two BlackFriday fixtures is intentional (existing tests explicitly index_model_records afterwards). Do NOT introduce Sidekiq::Testing branches into production. Affected inline fixture callsites were swept. Actual scheduled runner semantics are tested in job specs.
Check latest snapshot, not previous head. No tools that mutate production, secrets, flags, config. No code/PR edits. Return concrete findings or clean, not hypothetical requirements unsupported by current callsites.

Lease is renewed before each ES write and before progress acknowledgement, so a 25-product batch with retries cannot outlive a fixed lease unnoticed. Lost-token path raises, preserves progress, and never unlocks another owner. Per-request ES timeout is 15 seconds with five retries; lease is 10 minutes renewed between requests.

Separate QA audit code/specs/comments/evidence. Actual raw execution excerpts:
2472-current-head-full.log
large catalogue: products=1001, saves=10, indexed=1001, batches=41, max_batch=25, catchup_batch=25
offer-code batch: products=25, SELECTs_before=50, SELECTs_after=3, universal_lookups_before=25, universal_lookups_after=0
Finished in 3 minutes 1.7 seconds (files took 5.17 seconds to load)
237 examples, 0 failures
RSPEC_EXIT=0
2472-fairness.log
Finished in 54.29 seconds (files took 4.35 seconds to load)
2 examples, 0 failures
RSPEC_EXIT=0
2472-lease.log
offer-code batch: products=25, SELECTs_before=50, SELECTs_after=3, universal_lookups_before=25, universal_lookups_after=0
Finished in 45.01 seconds (files took 3.23 seconds to load)
7 examples, 0 failures
RSPEC_EXIT=0
2472-resumed-mutations.log
starve catalogue with targeted edits                 yes                          ReindexSellerOfferCodesJob advances the catalogue despite a targeted edit before every execution
reuse rolled-back destroy snapshot                   yes                          ReindexSellerOfferCodesJob does not reuse product IDs from a rolled-back destruction
skip failed-batch completion cooldown                yes                          ReindexSellerOfferCodesJob paces retries after a slow partial indexing failure; ReindexSellerOfferCodesJob releases its lock when the final cooldown write fails
recovery conflicts with exhausted worker             yes                          ReindexSellerOfferCodesJob schedules exhaustion recovery even while the failed job holds its unique lock
MUTATION_EXIT=0
