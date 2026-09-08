Review the current full diff for concrete regressions, P1/P2 only. Money-capable offer-code search values: human review, never merge. Previous findings and dispositions:
1. Recovery suppressed by UntilExecuting reacquisition: separate nonunique RecoveryJob invokes same paced worker. Specs use actual unique server middleware and prove ordinary enqueue is rejected while recovery survives. Recovery has own exhaustion retry.
2. Hot target starvation: monotonic Redis sequence scores put re-edited targets behind older pending targets; conditional score acknowledgements preserve concurrent edits; targeted/catalogue alternate.
3. Stale destroy snapshot: used only when destroyed?; rollback/reload/successful-save regression.
4. Failed final cooldown skipped unlock: nested ensure attempts unlock independently.
5. Deleted catalogue: alive scope, targeted deleted rows remain eligible cleanup.
6. Missing index: HEAD exists check before processing; missing alive document fully indexed rather than acknowledged empty; missing-index real test (not stubbed error).
7. Timestamp ties: existing Link#product_and_universal_offer_codes itself uses (product_codes + universal_codes).sort_by(&:created_at), no SQL order or ID tiebreak. Do NOT claim it already sorts IDs. Preserve existing semantics; frozen-time cross-source cap parity tested.
8. Sidekiq::Testing.inline! executes scheduled jobs immediately. Test-only fake! around two BlackFriday fixtures is intentional (existing tests explicitly index_model_records afterwards). Do NOT introduce Sidekiq::Testing branches into production. Affected inline fixture callsites were swept. Actual scheduled runner semantics are tested in job specs.
Check latest snapshot, not previous head. No tools that mutate production, secrets, flags, config. No code/PR edits. Return concrete findings or clean, not hypothetical requirements unsupported by current callsites.
