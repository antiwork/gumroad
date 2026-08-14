Review antiwork/gumroad PR #7220 branch fix/audience-member-lockwait at 197c34c89b3c2f5519e33c5f1810c4e271e62c76 vs origin/main.

Money-adjacent checkout change. Purchase/unsubscribe/subscription no longer write audience_members inline. They schedule RefreshAudienceMemberJob. Follower/affiliate keep incremental inline writes and fall back to the same job on LockWaitTimeout.

Delta since last clean review (e9a588b4):
- Purchase hooks moved after_save → after_commit (on: create/update and destroy).
- perform_in(1.minute) → perform_async everywhere (purchase + follower/affiliate fallbacks).
- Job lock :until_executed + on_conflict: :replace → :until_executing (no on_conflict).
- Spec support stubs/prepends now wrap perform_async, not perform_in.

Numbered hunt list:
1. after_commit dirty tracking: schedule_audience_member_refresh_if_changed reads previous_changes / email_previously_was / previously_new_record?. In this app's Rails version, do those survive into after_commit, or must it be saved_changes / email_before_last_save? If previous_changes is empty after commit, NO purchase save schedules a refresh — silent projection stall. This is the highest-value item.
2. CALLER COVERAGE: every add_to/remove_from/rebuild/schedule/update_audience_member_details caller — moved / left inline deliberately / missed. Purchase request path must not still write the projection inline.
3. RESURRECTION / LOST-WRITE across the async gap (now zero-delay, not 1 minute). Inverse op (unsubscribe, refund, destroy, email change, subscription deactivate) between enqueue and perform. refresh! must re-read live eligibility. Missing re-check is a blocker.
4. lock: :until_executing without on_conflict: can two concurrent commits enqueue two jobs that both run? Is that correct (refresh! last-writer-wins) or a thundering herd on the same row? Does until_executing still coalesce queued-not-started jobs, or only prevent a second start while waiting? A mid-run follow-up that itself races another follow-up must not drop the newest state.
5. Does it still stop the reported checkout/unsubscribe LockWaitTimeout 500? Remaining in-request follower/affiliate writes are stated as non-checkout; verify.
6. Who reads audience_members synchronously after checkout/unsubscribe? Immediate perform_async (no 1-minute delay) changes the stale window — name remaining readers and whether any buyer-visible path still waits on the row.
7. after_commit on: :destroy + schedule_audience_member_refresh: is email/seller_id still readable? Nested transactions / rollback of an outer txn after an inner commit?
8. Specs: the new "locks only until execution" example asserts get_sidekiq_options, not that a mid-run enqueue is kept. The wrap_original example mutates during perform — does that actually go through after_commit, or can it pass while production still drops the follow-up? Pair "not written in-request" / "no enqueue on rollback" with a positive create/update enqueue + job run to the same final state.
9. Minitest helper now prepends perform_async. Is it loaded? Does prepend beat Sidekiq::Testing.fake!? Any remaining perform_in call the helper no longer intercepts?
10. Comments claiming a 1-minute delay / unique lock / on_conflict:replace — blocker only if they describe a live safety property that is now false.

Do not run the suite. Read-only. Verdict READY-TO-MERGE or CHANGES-REQUIRED with P0/P1 file:line + one-line fix.
