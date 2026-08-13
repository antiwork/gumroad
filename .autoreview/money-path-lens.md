# Domain lens: post-charge duplicate window for physical products (gp#2126 / gumroad#7228)

This is ROUND 3 at `46549a0eea1beb4dcfd0226ba4ca12b869c4cbae`.
Money-path: `Purchase#not_double_charged` is a create-time charge gate.

## Diff vs main

`last_allowed_purchase_at` used to be one 10-second bucket for
`upgrade || quantity_enabled || is_physical || is_licensed`.
This PR splits `link.is_physical` FIRST to `2.hours.ago`, leaving the other three at 10 seconds.

HEAD commit `46549a0ee` ("Pin the 2-hour window for overlapping physical products") only:
- adds a comment that physical-first is deliberate for quantity-enabled overlaps
- renames the three physical tests to say "quantity-enabled" and `assert product.quantity_enabled`
- adds one physical+licensed test at 90 minutes

`create_physical_product` in `test/support/model_factories.rb` ALWAYS sets `quantity_enabled = true`.

## Prior panel findings — grade each RESOLVED / STILL-OPEN / REGRESSED with file:line

1. **[P1] Physical-first precedence silently extends quantity-enabled / licensed / upgrade physical reorders to a 2-hour window** (`app/models/purchase.rb:5337` at prior heads).
   Authors chose option (b): keep 2-hour for every physical overlap and pin it.
   Verify whether the NEW tests actually pin that product decision:
   - quantity-enabled: factory already forces `quantity_enabled = true`. Does `assert product.quantity_enabled` uniquely kill a mutant that restored 10s for `quantity_enabled` overlaps, or is it tautological?
   - licensed: new test uses `create_physical_product` then `update!(is_licensed: true)` — so it is physical+quantity_enabled+licensed, not a licensed-only overlap. Does any example uniquely fail if licensed overlap is moved back to 10s?
   - upgrade: is there STILL no physical+upgrade example?
   Mark RESOLVED only if each overlap the prior P1 named is pinned by a unique reddening example. Otherwise STILL-OPEN.

2. Do NOT re-raise the same P1 as a new finding if you mark it STILL-OPEN — one disposition line is enough.

## Numbered checklist (this head)

1. **Preference-chain order is the whole change.** Mutate by INVERTING the chain (`quantity_enabled/licensed/upgrade` first, physical last), not by deleting the 2-hour branch. Which example uniquely reddens? If none, the order is untested.

2. **Factory tautology.** Because `create_physical_product` always sets `quantity_enabled = true`, the three renamed tests cannot distinguish "physical" from "physical+quantity_enabled". Demand whether a physical product with `quantity_enabled: false` is a real production shape; if yes, it is untested; if no, say so and do not invent a P1.

3. **Upgrade overlap.** `is_upgrade_purchase?` is still in the 10-second elsif. A physical membership/upgrade that is also `link.is_physical` now gets 2 hours. Is that reachable? If yes and untested, that is the remaining hole from finding 1.

4. **Confirmation path still works for the NEW window.** `confirmed_duplicate_purchase` only rejects successful priors. Confirm the 90-minute confirmed-repeat example actually hits the physical 2-hour branch (not an earlier return: bundle, automatic, gift receiver, `allow_double_charges`, SKU mismatch).

5. **Non-physical siblings must stay at 10 seconds.** Digital licensed / quantity-enabled / upgrade examples must still allow a repeat after 11 seconds. A mutant that applies 2 hours to the whole old OR-bucket must redden those existing tests.

6. **Gift lookup uses the SAME `last_allowed_purchase_at`.** Widening physical to 2 hours also widens the gift-to-same-recipient window. Is that intended? Is it tested?

7. **Time-boundary pin.** Specs use `90.minutes.ago` and `121.minutes.ago` as literals (good). Confirm they do not derive from `2.hours`. Mutating `2.hours.ago` → `10.seconds.ago` must redden the 90-minute examples.

8. **Money-path blast.** This is a create-time charge gate, not a display-only check. A false-positive confirmation now blocks a successful charge until the buyer clicks "Buy again". Grade false-positive (blocking legitimate rapid physical reorders for 2 hours) vs false-negative (the production clusters the PR exists to stop). Do not treat a deliberate product decision as a defect if the tests pin it; DO treat an unpinned overlap as a defect.

9. Restore any mutated files. Do not push, comment, or edit the working tree you were given.

Verdict: READY-TO-MERGE or CHANGES-REQUIRED. P1 = merge-blocking unpinned money-gate behaviour.
