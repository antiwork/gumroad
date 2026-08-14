# Domain lens: suppress a risk detector while an autonomous recovery job is live

This PR adds ONE early return to `AlertOnBlockedEstablishedBuyersJob#perform`:

```
return if Feature.active?(:auto_recover_stranded_buyers) && scan[:stranded].any?
```

Claim: `RecoverStrandedBuyersJob` already scans the same `Risk::StrandedBuyerScanService` population and emits its own outcomes report, so the per-buyer list is duplicate noise. Truncation-with-nothing-qualifying is deliberately kept (recovery job `return if scan[:stranded].empty?` and never emits that edge). `AlertOnBlockedEstablishedSubscribersJob` is deliberately untouched.

Review as a RISK detector-suppression, not a money-move. Numbered checks:

1. **False-positive of the suppress (primary).** When the flag is live AND `scan[:stranded].any?`, this job now goes silent. Construct the cases where that silence is WRONG: recovery job did not run / lock-missed / out of budget / rotation bucket skipped this buyer / recovery job failed after `retry: 1` / recovery reported escalations a human still needs to see / recovery report is a counts-only summary that no longer names the buyer. Read `RecoverStrandedBuyersJob` (not the comment) and say which of those the outcomes report still covers vs which become a new blind spot.

2. **Is the recovery job's empty-scan early return actually as claimed?** Confirm `return if scan[:stranded].empty?` (no `truncated` exception) is live on origin/main AND this branch. Confirm this alert's truncation-with-nothing-qualifying path still reaches `InternalNotificationWorker` when the flag is on. Name any other recovery-job exit that is silent while this new guard is also silent.

3. **Flag-off rollback.** With the flag off, the new line must be a no-op. The existing specs that fire the report must still be reachable. A spec that only stubs the flag on does not pin the rollback.

4. **Wrong layer / feature-suppression-is-not-a-fix.** This is an intentional de-dupe of a now-redundant human report (gp#2106: run risk alerts autonomously, stop routing routine findings). That is NOT "disable a feature to dodge a bug." Do NOT reject the premise. DO reject it if the recovery job does not actually emit a substitute signal for the same stranded-buyer population. Argue with file:line.

5. **Sibling detector completeness.** `AlertOnBlockedEstablishedSubscribersJob` is claimed out of scope (different population; no autonomous subscriber recovery). Verify that claim against the subscriber job + recovery job, then say whether any OTHER `InternalNotificationWorker` "Blocked established" / stranded-buyer report is now a leftover duplicate.

6. **Independent flags / combined state.** The guard is `flag && stranded.any?`. Enumerate the four-cell truth table (flag on/off × stranded empty/any, plus truncated). Confirm both-true is the ONLY silent-per-buyer cell, and that truncated+empty still notifies.

7. **Spec vacuity.** `not_to have_received(:perform_async)` is vacuous against `def perform; end`. Demand which example reddens if (a) the flag conjunct is dropped, (b) the `.any?` conjunct is dropped, (c) the truncation-keep path is deleted. Name any mutation that no new example catches.

8. **Comment claims are findings.** Grade every factual claim in the new comment (same population, recovery emits outcomes, recovery returns early on empty scan, truncation line is unique). False comment = P1 on a detector.

9. **Do not invent money-path defects.** This job reports; it does not unblock, refund, or charge. A finding that money moves here is wrong unless you quote the call site.
