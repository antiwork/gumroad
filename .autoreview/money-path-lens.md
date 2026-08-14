# Domain lens: post-charge duplicate window for physical products (gp#2126 / gumroad#7228)

This is ROUND 5 at `a9222ed6ecb3f9ee19780308c1e842ccc4c9d4f5`.
Money-path: `Purchase#not_double_charged` is a create-time charge gate.

## Diff vs previous reviewed head `0ab7665e5`

HEAD commit `a9222ed6e` ("Keep physical subscription upgrades on the 10-second window"):
- REVERSES the prior physical-first preference: `is_upgrade_purchase?` now wins and stays on `10.seconds.ago`, even when `link.is_physical`.
- Accidental physical retries (quantity-enabled / licensed overlaps) still use `2.hours.ago`.
- Adds two examples: physical+upgrade at 90 minutes must be valid; physical+upgrade at 5 seconds must require confirmation.

This is an intentional product decision change vs the previous head, not a no-op.

`create_physical_product` in `test/support/model_factories.rb` ALWAYS sets `quantity_enabled = true`.

## Prior panel findings at `0ab7665e5` — grade each RESOLVED / STILL-OPEN / REGRESSED with file:line

1. **[P1] Physical-upgrade precedence unpinned** (`app/models/purchase.rb:5341` at `0ab7665e5`).
   Prior reviewer: no example uniquely covered both `link.is_physical` and `is_upgrade_purchase?`. This head adds two such examples AND flips the intended winner to upgrade/10s.
   Grade RESOLVED only if the NEW 90-minute upgrade example uniquely reddens when the chain is inverted back to physical-first (`if link.is_physical ... 2.hours ... elsif is_upgrade_purchase?`). Do NOT re-raise the old "physical should win" finding — that is no longer the claimed behavior. If the new examples are vacuous (an earlier return, SKU mismatch, or quantity_enabled 10s branch would also accept the 90-minute retry), mark STILL-OPEN.

2. **[P1] Exact two-hour boundary unpinned** (`test/models/purchase_test.rb:2698`).
   Prior reviewer: 119 and 121 minutes do not pin inclusive vs exclusive at exactly `2.hours.ago`. This head did not add a frozen prior at exactly two hours.
   Grade STILL-OPEN unless a new exact-equality example exists. Do NOT invent a new finding number for the same gap.

## Numbered checklist (this head)

1. **Preference-chain order is the whole production change.** Mutate by INVERTING upgrade vs physical (`if link.is_physical; 2.hours.ago; elsif is_upgrade_purchase?; 10.seconds.ago`), not by deleting either branch. Which example uniquely reddens? Demand exactly the new 90-minute upgrade example.

2. **New 5-second upgrade example.** Confirm it is not satisfied by the physical 2-hour branch (that branch would also reject a 5-second prior). The load-bearing half is the 90-minute ALLOW. The 5-second DENY only pins that upgrade did not become unlimited.

3. **Factory tautology.** `create_physical_product` always sets `quantity_enabled = true`, so physical+upgrade fixtures are also quantity-enabled. Quantity is also 10 seconds. A mutant that drops the upgrade branch entirely (`if link.is_physical; 2.hours; elsif quantity/licensed; 10.seconds`) should redden the 90-minute upgrade example. If it stays green, the upgrade term is dead and finding 1 is STILL-OPEN / REGRESSED.

4. **Reachability.** Is `is_upgrade_purchase? && link.is_physical` a real production path (physical membership / subscription updater)? Grep callers. If unreachable, say so and do not invent a P1 about the carve-out; the accidental-retry 2-hour window is still the money risk.

5. **Non-upgrade physical siblings must stay at 2 hours.** Quantity-enabled and licensed physical examples at 90 / 119 minutes must still require confirmation. A mutant that applies 10 seconds to all physical products must redden those.

6. **Non-physical siblings must stay at 10 seconds.** Digital licensed / quantity-enabled / upgrade examples must still allow a repeat after 11 seconds.

7. **Confirmation path** still works on the physical 2-hour branch (`confirmed_duplicate_purchase` only rejects successful priors).

8. **Gift lookup uses the SAME `last_allowed_purchase_at`.** Upgrade-first also shortens the gift window for an upgrade purchase. Intended? Tested?

9. **Exact 2-hour equality** (finding 2). 119 vs 121 does not pin `>` vs `>=` on `created_at > last_allowed_purchase_at`.

10. Restore any mutated files. Do not push, comment, or edit the working tree you were given.

Verdict: READY-TO-MERGE or CHANGES-REQUIRED. P1 = merge-blocking unpinned money-gate behaviour.
