# STEER — Greptile review on PR #7802 (posted 2026-09-19T06:39:47Z), verified against this branch

Do not commit this file; delete it before `gh pr ready`.
You are still the owner of this PR. Nothing here replaces your own judgement — but each finding
below was checked against the code at your head (338d6f1d4) and your uncommitted worktree, so do
not re-derive them; just fix or refute each one and commit the specs.

Greptile reviewed commit `338d6f1d4` only, where 96 lines of source and **zero specs** were pushed.
Your uncommitted spec work (10 files, 194 insertions) therefore already answers finding 6 —
commit it and mutation-prove it; do not treat finding 6 as a reason to start over.

## Finding 1 — `licenses_controller.rb:141-142` — VALID, but the fix is "do not silently serve the weaker path"

Verified mechanism, in this order (`fetch_valid_license`):
- `params[:product_id]` blank → `License.find_by(serial:)` is a **global** lookup, so `product` is the
  license's own product; per-product binding is gone and the only remaining tie is
  `product.matches_permalink?(params[:product_permalink])`.
- `force_product_id_timestamp` governs whether that legacy shape gets a **500** (the nudge onto
  product_id). Returning `nil` here therefore turns "enforcement could not be read" into
  "no enforcement", and the request is served through permalink-only binding.
- Pre-PR (main), the un-rescued raise produced a 500 — i.e. main fails **closed** on this path and
  the rescue makes it fail **open**. That is the one direction your brief told you not to take:
  "fail the direction that cannot widen enforcement or skip a check that the flag's absence would
  enforce."

Direction: an unread timestamp must not be indistinguishable from "no enforcement".
- Preferred: memoize the last timestamp this process read (same shape you already used for
  `auth_presenter` — process-level, presenters are per-request).
- If there is no last-known value, degrade toward enforcing (keep the existing 500 for the legacy
  no-`product_id` shape) rather than serving through the permalink-only comparison.
- Note the twin: `skip_product_id_check` already degrades to `false` = enforce, which is correct —
  keep the two reads pointing the same way, and say so in the PR body.
- Also check `test/models/link_test.rb:1338–1343` before writing the body sentence; Greptile's claim
  that post-cutoff products may reuse another seller's permalink is the premise of its escalated
  severity. If that claim is true, one sentence in the body is required regardless of which
  fallback you pick.

## Finding 2 — `validate_recaptcha.rb:155-157` — VALID (P1), narrow it

Verified: `recaptcha_passes?` line ~98 is `score_ok = threshold.nil? || (scored && assessment[:score] >= threshold)`,
so `nil` disables score gating unconditionally, and the rescue returns
`RECAPTCHA_SCORE_THRESHOLD_DEFAULTS[surface.to_sym]` — which is the **lenient** default (0.4 / 0.3)
and is `nil` for every surface absent from that hash. An operator override of e.g. `checkout_score`
0.9 is silently replaced by 0.4 on a stall, and an override on a non-default surface (`login`, …)
is replaced by no gating at all.

Direction: a *configured* threshold must not be downgraded to the built-in default. Memoize the last
value read per surface this process (same pattern as `auth_presenter`); when nothing is known, do not
return a value that is weaker than what the key would have held — prefer treating the threshold as
unavailable and failing the score gate, and state in the body how that interacts with
`RECAPTCHA_FAIL_OPEN_DEFAULTS` (checkout/follow are already fail-open for `infra_error`; do not make a
stall silently more permissive than the configured value).

## Finding 3 — `impersonate.rb:38-40` — VALID (P1), and this is the worst of the six

Verified end to end on this branch:
- `app/controllers/concerns/logged_in_user.rb:11` — `logged_in_user = impersonated_user || current_user`.
- `app/controllers/concerns/current_seller.rb:40-51` — `valid_seller?` is
  `logged_in_user.member_of?(seller)`; failing that, `reset_current_seller` sets
  `@_current_seller = logged_in_user`.
So a stalled impersonation read makes the staff member their own `current_seller`, and a seller
settings/profile write submitted through the impersonation session lands on the **staff account**.
`find_impersonated_user_from_redis` is not a "read the page" read — it is the identity binding — so
`nil` is the wrong degrade even though `nil` is right for an expired key.

Direction: an unread impersonation mapping must not resolve to a different identity. Either keep the
last known mapping for the request/session, or fail the request (the pre-PR behaviour was an
exception → 500, so failing closed is not a regression). Do not leave `nil` as the transport-error
answer with "same as an expired key" as the justification.

## Finding 4 — `home_page_numbers_controller.rb:19-21` — VALID (P2)

Verified: `prev_week_payout_usd` is called **inside** the `Rails.cache.fetch("homepage_numbers", expires_in: 1.day)`
block, so the degraded `nil` is formatted and memoized as `{ prev_week_payout_usd: "$" }` in
Memcached — outliving the stall by up to a day, on a number the homepage publishes.

Direction: keep the degraded response outside the cache write (a transport failure must not be cached;
a legitimately unset key may still behave as today). Add a spec pinning that a failing read does not
populate the cache.

## Finding 5 — `user_balance_stats_service.rb:39-41` — VALID (P2)

Verified: `app/sidekiq/update_user_balance_stats_cache_worker.rb` has `sidekiq_options retry: 1,
queue: :low, lock: :until_executed` and its entire body is `write_cache` inside a 1-hour query
timeout. Swallowing `setex` makes the worker report success, so the configured retry never fires and
the computed stats are discarded. The comment's premise ("the caller already has its answer") is
false for that caller.

Direction: request-path degradation does not require suppressing worker failure — let the write raise
from the worker path (or explicitly reschedule), while keeping the request path non-raising. Add the
worker spec.

## Finding 6 — `config/redis.rb:8` — TRUE AT THE REVIEWED HEAD, ALREADY IN FLIGHT

Greptile saw a commit with no specs. Your worktree has ten spec files modified; commit them.
Before ready, each changed branch needs a spec that fails **against `origin/main`'s source** (prove it
with a real run) and the sabotage pass per the brief: remove each rescue, re-run the owning spec, must
redden, restore with `git checkout HEAD -- <file>`, verify byte-identical.
Cover explicitly, per Greptile and your own brief: unset-vs-unread picker limit; signup stats retained
across presenter instances; exclusion-set failure caching nobody; the three security fallbacks above.
Isolate the new class-level signup state between examples (a leaking class-level memo makes the suite
order-dependent).

## Do not

- Do not reply on the PR thread for this review. Your comment budget is one, and only if a reviewer
  thread asks you something; the PR body stays the status surface (add a one-line Note that the
  round-1 Greptile P1s were addressed and which fallback direction was chosen for each).
- Do not post "will fix" anywhere. Fix, push, re-run the panel at the new head, re-pin
  `Premerge review: clean @ <head-sha>`.
- No force-push, no amend. Same worktree, same branch.
