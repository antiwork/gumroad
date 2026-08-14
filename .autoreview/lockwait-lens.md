Review antiwork/gumroad PR #7220 branch fix/audience-member-lockwait at 650a4e6e7e92f4289d085b8b5f1df19ec1c572a9 vs origin/main.

Money-path checkout change: purchase/unsubscribe/subscription no longer write audience_members inline; they schedule RefreshAudienceMemberJob. Follower/affiliate keep incremental inline writes and fall back to the same job on LockWaitTimeout.

Newest commit (650a4e6e) claims to defer refresh enqueues to commit for mid-transaction callers (follower/affiliate fallbacks + purchase after_commit dirty-tracking). Prior head 197c34c89b was reviewed dirty. Re-grade those findings as RESOLVED / STILL-OPEN / REGRESSED against THIS tip:

1. Subscription#deactivate!/restart/update enqueue RefreshAudienceMemberJob inside an outer transaction; job can read pre-commit state. File then: app/models/subscription.rb:497.
2. Follower/affiliate LockWaitTimeout fallbacks enqueue perform_async inside the still-open save transaction.
3. after_commit reading previous_changes only sees the LAST save in the transaction; a watched change followed by an unwatched save skips the refresh; email_previously_was lost.
4. :until_executing uniqueness lock allows overlapping refresh jobs; older refresh can overwrite newer state.
5. Same as (2) from the other engine: enqueue lock-timeout reconciliation only after source commit.
6. Same as (1) from the other engine: defer subscription-triggered refreshes until subscription commit.

Numbered hunt list for this class (inline write moved to a job):
1. CALLER COVERAGE: every add_to/remove_from/rebuild/schedule/update_audience_member_details caller — moved / left inline deliberately / missed. Purchase request path must not still write the projection inline.
2. RESURRECTION across the async gap: inverse op (unsubscribe, refund, destroy, email change, subscription deactivate) between enqueue and perform. refresh! must re-read live eligibility.
3. Does it actually stop the reported checkout/unsubscribe LockWaitTimeout 500, or do remaining in-request writes still contend on the same row?
4. Job failure handling: missing row / replica lag; retry of LockWaitTimeout; uniqueness/coalesce; perform(email, seller_id) id kinds. Mid-run follow-up must not be dropped.
5. Who reads audience_members synchronously after checkout/unsubscribe? A stale row on a buyer-visible path is a blocker.
6. Enqueue-inside-transaction: every perform_async/perform_in on this job must be after the source transaction commits (purchase, follower, affiliate, subscription).
7. previous_changes / dirty tracking across multi-save transactions — accumulate per-save, consume after_commit.
8. Specs: pair "not written in-request" with positive enqueue + running the job to the same final state. Vacuous "jobs empty" / "not receive" without a positive control is a miss. Each prior P1 that is claimed fixed needs a load-bearing example.

Do not run the suite. Read-only. Do not modify files. Verdict READY-TO-MERGE or CHANGES-REQUIRED with P0/P1 file:line + one-line fix.
