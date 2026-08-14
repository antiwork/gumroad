Review antiwork/gumroad PR #7220 branch fix/audience-member-lockwait at 9f3b58d8c03ba9ec02d3acdf13e09c94637f14d9 vs origin/main.

Money-path checkout change: purchase/unsubscribe/subscription no longer write audience_members inline; they schedule RefreshAudienceMemberJob. Follower/affiliate keep incremental inline writes and fall back to the same job on LockWaitTimeout.

Newest commit (9f3b58d8c0) claims: AudienceMember#refresh! uses with_lock (not bare lock!) so FOR UPDATE holds through the source reads and save. Prior head 6505027227 used bare lock! which is a no-op under autocommit. Re-grade that finding as RESOLVED / STILL-OPEN / REGRESSED.

Already resolved at earlier tips (do not re-open unless regressed):
1/2/5/6. Enqueues are AfterCommitEverywhere / after_commit.
3. Watched changes accumulated in after_save, consumed in after_commit.
4. :until_executing kept so mid-run follow-ups enqueue; serialization is via with_lock in refresh!, not a Sidekiq lock-mode change.

Hunt the with_lock claim specifically: refresh! must be `persisted? ? with_lock { apply_refresh } : apply_refresh` (or equivalent transaction wrapping the whole rebuild). Bare lock! at the top of refresh! is NOT sufficient. Keep :until_executing.

Residual accepted (not a blocker): new-record creates have no row to lock; RecordNotUnique + Sidekiq retry converges.

Do not run the suite. Read-only. Do not modify files. Verdict READY-TO-MERGE or CHANGES-REQUIRED with P0/P1 file:line + one-line fix.
