# Change class: one-off repair/backfill service that MOVES MONEY

For `Onetime::*`-style services that replay a missed webhook, re-book a stranded outcome, or
backfill a ledger across a cohort. Blast radius is real (this checklist found three P1s across
695 rows of stuck Stripe disputes), and the failure mode is silent: the row goes terminal, so
nobody can ever find it again.

Feed these as NUMBERED items in the reviewer brief. Bare "review this" produces a rubber stamp.

## The checklist

1. **Idempotency / double-credit.** Run it twice, or let a real webhook land mid-run — is the
   seller credited twice? Follow the handler all the way to the balance mutation. Is there a
   state guard, a uniqueness constraint on the event id, or *nothing*? A never-persisted event
   PORO means there is no dedupe at all; often the only guard is the state machine raising on a
   repeat transition. Name what protects it, or say plainly that nothing does.
2. **Was the internal side of the transaction ever completed?** ⚠️ The highest-yield question.
   A repair that replays the CLOSING step onto a row whose OPENING step never ran will credit a
   debit that never happened (free money out of our pocket) or send the row terminal with the
   counterparty never debited (we eat the loss, permanently, and the ticket reads as fixed).
   Find where the debit is actually written — usually a `*_side_effects` method with its own
   `finished_at` column — and require BOTH the state and the completion stamp.
3. **State-machine legality of every scanned state.** Enumerate the model's real transitions.
   A state included in the scan but absent as a transition SOURCE raises mid-cohort, aborts the
   run, and crashes again on re-run. Cross-check the scan constant against the machine, not
   against the ticket's prose.
4. **Managed/destination vs. platform vs. connected accounts.** These settle differently. If the
   live path books the outcome on a *different event* for one account type (e.g. funds-reinstated
   rather than dispute-closed) and that path also **moves real money onward**, replaying only the
   internal booking credits the counterparty on paper with nothing behind it. Refuse that
   population for manual repair rather than half-booking it.
5. **Flow-of-funds parity with the live path.** Compare sign, currency (presentment vs merchant
   vs USD) and leg structure against how the real handler builds it. A simple single-leg
   construction can drop the merchant legs downstream balance code reads first.
6. **Every disputable/subject variant.** The polymorphic parent usually admits a third kind
   nobody remembers. `a || b` returns nil for it → NoMethodError aborts the run. Also check
   association helpers that return `[nil]`, which is `.presence`-truthy and defeats a `.compact`
   fallback.
7. **Per-row failure isolation.** `find_each` with no rescue means row 300 raising discards the
   in-memory report for rows 1-299. Each row needs its own begin/rescue recording the failure.
   Rescue the whole vendor error class, not one subclass — a year-old cohort WILL hit permission
   errors from disconnected accounts, rate limits, and connection errors.
8. **Atomicity per row.** If the live handler wraps itself in a transaction on one path but not
   the other, the unwrapped one can leave the row terminal with half its per-item loop applied —
   and terminal means no re-run ever revisits it.
9. **Audit-trail honesty.** A handler that early-returns is a NO-OP, not a booking. If the code
   still counts it `booked_*` and writes `action: "booked"`, the audit trail lies about a money
   movement. Re-read the row after acting and report `book_had_no_effect` with the end state.
10. **Dry run is the default, and reaches only reads.** Verify `dry_run: true` short-circuits
    before every write, on ALL entry points (class method AND instance method).
11. **Vacuous specs on the money assertion.** The single most important effect — the credit — is
    the one most often unasserted. `expect { }.to change { Credit.count }` or the spec passes
    even if crediting is skipped entirely. Also pin each refusal with a real negative assertion
    (no balance moved), not merely that a counter says "refused".
12. **Scan-state completeness.** A hardcoded state list that misses one non-terminal state leaves
    those rows stranded forever while the ticket reads fixed. Enumerate from the model.

## Fixture lesson

Adding guard (2) will REDDEN existing specs whose fixture omitted the completion stamp that
production always sets. That is a signal about the FIXTURE, not the guard. Fix the fixture.

## PR body / QA owed

- Size EACH refusal reason before booking anything — refusals are populations needing a human
  decision, not noise.
- Book ONE row first with an id filter, verify the balance moved, then batch with `limit:`.
- Flag the mailer fan-out: booking a whole cohort at once emails every affected seller in one
  burst. That is a deliberate decision, not a detail.
