Review antiwork/gumroad PR #7220 branch fix/audience-member-lockwait at 65050272277c72c1a47e04c73295636f6574d260 vs origin/main.

Money-path checkout change: purchase/unsubscribe/subscription no longer write audience_members inline; they schedule RefreshAudienceMemberJob. Follower/affiliate keep incremental inline writes and fall back to the same job on LockWaitTimeout.

Newest commit (6505027227) claims: (a) accumulate watched purchase changes in after_save and consume them in after_commit, so a watched change followed by an unwatched save still enqueues, and an email change still refreshes the old address; (b) AudienceMember#refresh! calls lock! if persisted? before reading source state, so overlapping :until_executing jobs cannot commit out of order. Prior head 650a4e6e7e was reviewed dirty on those two points. Re-grade them as RESOLVED / STILL-OPEN / REGRESSED against THIS tip.

Prior findings already resolved at 650a4e6e (do not re-open unless regressed):
1. Subscription#deactivate!/restart/update enqueue inside an outer transaction — wrapped in AfterCommitEverywhere.
2/5. Follower/affiliate LockWaitTimeout fallbacks enqueue inside the save transaction — same wrapper.

Still-open at 650a4e6e, claimed fixed here:
3. after_commit reading previous_changes only sees the LAST save. Look for an after_save accumulator (record_audience_member_refresh_trigger) and consume/clear in after_commit / after_rollback.
4. :until_executing allows overlapping perform. Look for lock! at the start of AudienceMember#refresh! (not a change of the Sidekiq lock mode — :until_executing must stay so mid-run follow-ups can enqueue).

Numbered hunt list:
1. CALLER COVERAGE: every add_to/remove_from/rebuild/schedule/update_audience_member_details caller.
2. RESURRECTION across the async gap: inverse op between enqueue and perform; refresh! must re-read live eligibility AFTER the row lock.
3. Does it stop the checkout/unsubscribe LockWaitTimeout 500?
4. Job failure handling; mid-run follow-up must not be dropped.
5. Who reads audience_members synchronously after checkout/unsubscribe?
6. Enqueue-inside-transaction: every perform_async on this job must be after the source transaction commits.
7. previous_changes / dirty tracking across multi-save transactions — accumulate per-save, consume after_commit.
8. Specs: the three new examples must be load-bearing (not vacuous).

Do not run the suite. Read-only. Do not modify files. Verdict READY-TO-MERGE or CHANGES-REQUIRED with P0/P1 file:line + one-line fix.
