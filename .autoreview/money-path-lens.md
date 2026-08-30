# Domain lens: checkout discount / offer-code money path (gp#2346)

This diff is a money-path change. A checkout discount's stored amount (cents vs percentage) is
what later `amount_off` uses to reduce the price a buyer is charged. Review as Sol adversarial
pre-merge, P1 bar. Do not run the suite. Read-only. Produce a full READY-TO-MERGE or
CHANGES-REQUIRED verdict in the final message.

## What changed

- `Checkout::DiscountsController` `#update` no longer nils `amount_percentage` unless the client
  actually submitted `amount_cents` (partial updates that omit both amount keys used to wipe the
  percentage, leaving a code with neither amount).
- `OfferCode#amount_off` returns 0 when `amount_percentage` is nil instead of raising.
- `OfferCode#price_validation` rejects non-tiered codes that are neither percent nor cents.

## Numbered checks

1. **Partial-update wipe: is the class closed?** Enumerate every writer of `amount_percentage` /
   `amount_cents` (controller create/update, mass-assign, API, admin/CLI, jobs). Does any sibling
   path still nil one field without writing the other? A name-only PUT that still 500s or still
   zeros the discount is in scope.

2. **`params.key?(:amount_cents)` vs blank/zero.** Does `amount_cents: nil` or `""` still take the
   elsif and wipe a live percentage? Is that intended conversion, or another wipe? Probe the
   permitted params and the create path's dual.

3. **`amount_off` returning 0 is a CHARGE-PATH change.** Returning 0 on a nil-percentage code
   charges full price instead of 500ing. Confirm every caller of `amount_off` (checkout, quote,
   receipt, upsell, subscription renewal). A silent full-price charge is worse than a 500 if
   checkout still accepts the code as valid. State whether fail-closed (reject the code) would be
   the correct money polarity.

4. **Validation vs runtime.** The new `price_validation` rejects new/updated nil/nil codes, but
   `amount_off`'s 0-guard is for rows that already exist. Are deleted, universal, or tiered codes
   excluded correctly (`!tiered?`)? Can a tiered code with nil amounts still hit `amount_off`?

5. **`is_percent?` / `is_cents?` definitions.** Read the predicates. If `is_percent?` is
   `amount_percentage.present?` (or `!amount_cents?`), the new validation's `!is_percent? &&
   !is_cents?` may be unreachable or overlap. Instantiate at nil/nil, 0, and percent=0.

6. **Display vs charge.** After a partial update, does the JSON presenter still show 50% while
   `amount_off` would now return 0 (or vice versa)? Same values on read and charge.

7. **Specs: load-bearing and non-vacuous.** Which example reddens if you restore the bare `else`
   that always nils percentage? Which reddens if you delete the `return 0`? Which reddens if you
   delete the new validation? Name any mutation nothing catches. The `rescue nil` count assertion
   is a smell — confirm it is not tautological.

8. **Hostile client values.** `amount_cents: 0`, negative, missing vs explicit null, percent-only
   create, cents-only create. Does create still convert percent→cents by niling the other field?

Verdict: READY-TO-MERGE or CHANGES-REQUIRED. P1/P2/P3 with file:line + one-line fix.
