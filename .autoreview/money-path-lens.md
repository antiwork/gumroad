You are reviewing a Stripe e-mandate interval change on Indian-card membership purchases (antiwork/gumroad, branch gumclaw/gp1410-restart-mandate-interval, head f2bbdc54ca63efa3c7f5a87a798d9f2ab4794cc7). Money path. Do NOT modify files. Do NOT run the test suite. Static review only; write the full verdict in the final message.

Diff in one sentence: `Purchase#mandate_options_for_stripe` now maps a FIXED recurrence interval (month/year/…) when `is_recurring_subscription_charge?` is true, not only for original/upgrade purchases. Goal: restart purchases that re-establish a mandate via `setup_future_charges` stop being sent to Stripe as `interval: "sporadic"`.

`is_recurring_subscription_charge` is `subscription.present? && !is_original_subscription_purchase && !is_gift_receiver_purchase` (no upgrade exclusion). The outer early-return that even produces a mandate is still `is_original_subscription_purchase? || is_preorder_authorization? || is_upgrade_purchase? || setup_future_charges`.

Numbered checklist — answer each item with evidence (file:line + quote):

1. REACHABILITY. Does a real restart purchase actually have `is_recurring_subscription_charge? == true` AND pass the outer guard via `setup_future_charges`? Trace `Subscription::UpdaterService` / `Purchase::CreateService` restart construction. If the production restart row is flagged differently (e.g. `is_original_subscription_purchase` flipped true, or no `setup_future_charges`), this change is dead and the new spec is a fixture of itself.

2. OVER-INCLUSION / CLASS COMPLETENESS. The new predicate is wider than "restart". Enumerate every purchase shape that is `is_recurring_subscription_charge?` AND also hits `mandate_options_for_stripe` (has `setup_future_charges` or is original/upgrade/preorder). For each: should it get a fixed interval or sporadic? Name any sibling that still ships `sporadic` but re-establishes a mandate on a fixed cadence (plan-change / card-update / installment / commission / gift / preorder). Partial coverage of the class is a P1 if the same root cause can be stated without naming "restart".

3. MONEY / STRIPE SEMANTICS. Changing `interval` from `sporadic` to `month`/`year` is a live e-mandate contract with the issuer (RBI / Stripe India). What happens to an existing sporadic mandate when a restart now requests a fixed one? Does Stripe reject the setup intent, silently replace, or create a second mandate? Grade whether this can block a paying restart. A ramp flag is not a correctness argument.

4. DISPLAY vs CHARGE vs MANDATE parity. Confirm `subscription_duration` on a restart purchase is the live membership cadence (not nil / not the original purchase's stale value). If nil, the `case` falls through and the purchase STILL ships `sporadic` — the new `if` is a no-op.

5. SPEC LOAD-BEARING / VACUITY. The new example stubs `chargeable` and `subscription_duration`. Does it actually exercise `is_recurring_subscription_charge?`, or would it stay green if that clause were deleted (because a stubbed duration + original/upgrade flag still maps)? Name the previous-variant mutant: revert the `|| is_recurring_subscription_charge?` only. If the example stays green, it is decoration. Also: `create_purchase` + `is_original_subscription_purchase: false` + `subscription:` — confirm that combination really makes `is_recurring_subscription_charge` true in this factory, not just in the comment.

6. INDEPENDENT-FLAG PRODUCT. `is_upgrade_purchase?` is already a subset of `is_recurring_subscription_charge?` for non-gift rows (upgrade ⇒ subscription present, not original). Adding the latter does not change upgrades. State that explicitly so it is not counted as extra coverage.

7. COMMENT ACCURACY. The new comment claims restarts "must be mapped like any other recurring membership charge". Recurring membership charges typically do NOT create a new mandate (they charge off-session on an existing one). Is the comment's "like any other recurring charge" claim true, or does it teach the next reader the wrong path?

8. CALL-SITE SWEEP. Grep every caller of `mandate_options_for_stripe` (Purchase, Order::ChargeService, SetupIntentsController, etc.). Does any caller pick a representative purchase whose flags would still yield `sporadic` for a cart that contains a restart? Cart/multi-buy already early-returns — confirm a restart in a multi-buy still gets a mandate somewhere else with the correct interval.

9. FAIL-CLOSED / FAIL-OPEN. If `subscription_duration` is an unexpected string, interval stays sporadic with no log. Is that the intended degradation for a restart, or should an unknown duration refuse the charge rather than register a wrong-shaped mandate?

Verdict format required:
- READY-TO-MERGE or CHANGES-REQUIRED
- Each finding as [P0|P1] path:line — one-line problem — one-line fix
- Checked Safe list (what you actually looked at)
- Do not report P2/P3 unless they are load-bearing for a P0/P1.
