# STEER — from the webhook session that received Greptile's review on gumroad#7819

Do not kill this session or re-clone. Read this, then finish these three items in this
worktree, in this order, before you exit.

Greptile reviewed `49a99cd` (2 findings). Current tip is `7eecf27`.

## 1. P1 — already fixed by you. Do NOT re-fix.

"Old Refunds Never Reconcile" (the permanent 60-day cutoff) is resolved at your tip:
`MINIMUM_AGE = 3.days` with `created_at: ...MINIMUM_AGE.ago` and no upper bound. Verified by
reading `git show 7eecf27:app/sidekiq/reconcile_pending_paypal_refunds_job.rb`. Nothing to do
except say so in the thread reply (item 3).

## 2. P2 — REAL, unfixed at your tip. Trim it now, BEFORE the panel verdict is pinned.

`app/sidekiq/reconcile_pending_paypal_refunds_job.rb` lines 3-7 are a five-line class comment;
`CLAUDE.md` ("Code comments") and Greptile both cap this at about three lines. Greptile scores it
mechanically, so it will come back as a finding again.

Replace exactly these five lines:

    # PayPal sends no refund-failed webhook — PAYMENT.CAPTURE.REFUNDED fires only when a
    # refund completes — so a refund PayPal accepted as PENDING and later failed keeps that
    # status on our row forever: it stays inside Refund.effective as money that moved, and
    # never reaches the FailedRefundException queue that exists to resolve it. This job is
    # the missing trigger, reusing the same service the Stripe lane already calls.

with these two:

    # PayPal does not send a webhook when an accepted refund later fails, so reconcile
    # pending refunds to ensure failures reach the existing exception queue.

Reason to do it now rather than after: a push invalidates the SHA-pinned
`Premerge review: clean @ <head>` marker. If the panel you just launched has already written its
verdict against the old head, re-run it after this commit and re-pin the marker in the PR body at
the NEW head. A comment-only trim keeps the prior spec/mutation evidence, but the verdict marker
must still match the presented head.

Do not touch the `MINIMUM_AGE` comment block — it explains the non-obvious "why" of the P1 fix and
is three lines.

## 3. One reply per Greptile finding, then done.

No gumclaw comment exists on the PR yet, so you have exactly one reply per finding available
(repo rule: one gumclaw comment while no human has replied; edit, never stack a second).

- P1 thread — reply id `4054579762`:
  `gh api repos/antiwork/gumroad/pulls/7819/comments/4054579762/replies -f body=...`
  Say the window is unbounded at the new head (candidate scope is `status = "PENDING"` alone;
  `MINIMUM_AGE` is a lower bound only), so a refund that never settles keeps being re-read.
- P2 thread — reply id `4054579771`: say the class comment is trimmed to the non-obvious reason.

Keep both to 1-2 sentences, plain text, no checkboxes, no em dashes in the reply bodies.
Run each body through `python3 ~/.hermes/scripts/comment_gate.py <file> --rewrite` first and read
the posted comment back by id.

## Guardrails

- Never force-push. If `origin` moved, pull --rebase and keep both heads.
- This is a draft with QA/Ship stages still unchecked. Do not mark it ready on CI-green alone; the
  pre-merge QA audit is a separate, later gate, and money-path work ("failed-refund queue") is a
  higher bar, not an exemption.
