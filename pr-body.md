## What

Comments only in `app/services/undelivered_receipt_notifier.rb`. **No behaviour change** — not one line of code was touched, renamed, or moved. `git diff` is entirely `#` lines.

Comment lines: **76 → 43**. Net −33.

docs-only — diff is the reviewable artifact

## Why

Every method carried a multi-paragraph essay: ticket citations (`gumroad-private#1635`, `#1545`, `#1397`), a production median, and a walkthrough of what the method name already says. The facts were right; the volume is what teaches people to skip the comments that matter.

Every fact a maintainer needs is still here, in fewer words.

## Deliberately KEPT (and why)

- **Fail-closed `notified?`.** Unreadable Redis must not send; `nil` rather than `true` so a caller can tell "already told them" from "cannot tell".
- **Fail-open `claim_send`.** SET NX, not read-then-write. An unusable store sends — silence is the failure this notice exists to break.
- **`track_for_retry` must not advance past a failed write.** The scan only queries forward, so a walked-past buyer exists nowhere else.
- **`record_sent` after delivery, never before.** Clear the retry set here, not at enqueue: a job that dies between the two would leave a buyer whose claim expires with nothing holding them.
- **Both halves of `undelivered?`.** A `sent` row can mean the provider never reported a delivery it made; an unopened page is a buyer who reads mail later. Judged over the whole send history — a resend adds a row.
- **Events before `sent_at` do not confirm.** `newest_sent_before` falls back to the newest row when the event predates every recorded send.
- **Free downloads excluded.** Nothing to refund, and they are where bounce volume lives.
- **`MAX_LISTED_PER_SELLER` applied at render, never by the sweep.** Truncating first lets ten recovered buyers suppress a digest a buyer outside the ten still needed.
- **`SETTLE_GRACE`.** Delivery events land in minutes; content access does not.

## Not slop (rejected from this PR)

- `LinksController` product-editor save comments — already trimmed in #7212; scan was stale against a dirty local branch.
- `PaymentForm.tsx` Apple Pay / Payment Element comments — Stripe wallet-token and remount traps, hard to re-derive.
- `Charge#lock_successful_purchases_in_id_order!` — deadlock / REPEATABLE READ / `json_data` dirty-record traps.
- `Purchase#receipt_purchase` — gift / membership / bundle receipt-resolution rules.
- `UpdateUserComplianceInfo` Japanese address / Singapore NRIC comments — Stripe verification traps.

## Test Results

- `ruby -c app/services/undelivered_receipt_notifier.rb` — Syntax OK
- `bundle exec rubocop app/services/undelivered_receipt_notifier.rb` — no offenses
- `bundle exec rspec spec/services/undelivered_receipt_notifier_spec.rb spec/sidekiq/alert_sellers_of_undelivered_receipts_job_spec.rb` — **57 examples, 0 failures**

comments only, no behaviour change

Premerge review: exempt (comments only, no behaviour change)
