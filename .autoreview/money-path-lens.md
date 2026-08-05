# Fraud / velocity counter adversarial review notes

Use this when reviewing changes to fraud velocity gates, card-testing rules, rate limits, or any security control that counts distinct actors/funding sources.

## Search for the existing dispatch helper BEFORE hand-rolling one

Measured 2026-08-02 on gumroad-private#1701, after **four** consecutive BLOCK verdicts on the same
counter. The concern already had, ~380 lines above the edit:

```ruby
def charge_processor_fingerprint
  stripe_charge_processor? ? stripe_fingerprint : card_visual
end
```

That is exactly the Stripe-vs-PayPal identity dispatch three revisions were spent re-inventing —
each new version introducing a fresh hole (wrong column, then PayPal invisible to the IP backstop,
then a key the attacker controls). Before writing any "which identity represents a funding source"
logic, grep the concern and its model for an existing predicate:

```bash
grep -n "fingerprint\|card_visual\|charge_processor" app/models/concerns/<area>/*.rb
```

Reusing the helper also inherits whatever provenance reasoning it already encodes, instead of
requiring the reviewer to re-derive it from scratch on every pass.

## N consecutive BLOCKs on one control ⇒ stop iterating, escalate the shape

Three or more review rounds where each fix introduces a *new* exploitable hole is not a code-quality
signal, it is a signal that the author lacks a fact only the domain owner has — here, whether **any**
server-attested payer identity exists on a *failed* PayPal row (the success path writes `card_visual`
at `paypal_charge.rb:51` from `order_details`, which a failed attempt never reaches). Iterating past
that point ships a fraud control that is weaker than `main` while every local suite reads green.

At that point the honest moves are: split the reviewed-clean half out and ship it alone, or hand the
contested half to someone who can consult the risk owner. Say so plainly rather than attempting a
fifth revision — a narrowed fraud rule that nobody can prove is sound is worse than the false
positives it was written to fix.

## Provenance beats names and specs

Do not accept a column/field name or test helper label as proof that a value is trusted. Trace the production write path:

1. Where is the value first accepted from the request/client?
2. Is it overwritten by a processor/server-attested value before the failed row is persisted?
3. Does the success path copy the attested value back to the model, and does the failure path ever get that object?
4. Do specs vary the field as if it were trusted while production gets it from client params?

Example pattern: switching a PayPal wallet counter from checkout email to `card_visual` looks safe if specs treat `card_visual` as payer identity, but it is still attacker-controlled if `Purchase#card_visual` is populated from checkout params / chargeable visual and the server-fetched PayPal capture visual is never saved to the failed purchase row.

## Caps before distinct counting are security-sensitive

A cap like `order(created_at: :desc).limit(N).pluck(...).uniq.size` changes the predicate from “has this actor reached K distinct units in the rule window?” to “are there K distinct units in the newest N rows?” Duplicate padding can evict older distinct evidence. Prefer a database-side `COUNT(DISTINCT CASE ...)`, grouped query, or early-stop-by-distinct-units strategy so duplicate rows cannot hide prior distinct cards/wallets.

## Processor allow-lists can be coverage loss

If a diff restricts counted rows to processors with understood fingerprints, compare each affected rule to `main`, not just the intended rule. A buyer/IP rule may already have been processor-scoped while an all-time browser-guid backstop counted all processors with fingerprints. Verify legacy processors (e.g. Braintree PayPal/cards) are actually dead before treating the exclusion as neutral.

## Review prompt additions

When the PR claims to fix a prior fraud-counter finding, explicitly ask:

- Is the new key server-attested on the exact persisted failed row the counter reads?
- Do specs construct production-shaped failed rows, including failure paths where successful charge objects are absent?
- Is any scan limit applied before distinct/grouping? If yes, can duplicate padding undercount?
- Did a processor/status allow-list drop a backstop that `main` still had?
