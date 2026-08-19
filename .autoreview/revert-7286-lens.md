# Domain lens: revert of the digital no-refunds floor (#7286)

This PR reverts #7286. Digital products (and account-level policy) may use **No refunds allowed** / 0-day again. Physical is unchanged. #7289 (no-refunds *claims* in fine print) must stay in force.

Review as a money-path eligibility **narrowing** (fewer buyers can request refunds) plus a restore of a previously-removed option. Numbered checks:

1. **DISPLAY vs ENFORCEMENT.** Grep every caller of `effective_max_refund_period_in_days`, `max_refund_period_in_days`, `refund_policy`, `within_refund_period?`, and the purchase snapshot writer. For each: does it set a PRICE, decide whether a refund is allowed, or render a period? After this revert, a digital product with stored 0-day must show 0-day AND refuse refunds. A 0-day receipt with a leftover 7-day gate (or the inverse) is a P0/P1.

2. **Where the period is applied vs where the snapshot is written.** Purchase#create snapshots the period. Existing purchases keep the stored snapshot. Confirm refund-request time uses the SNAPSHOT, not a live recompute that would close already-open 7-day sales — or, if live recompute is intended, that it is stated and tested. Name which path is live.

3. **Leftover floor.** #7286 introduced a 7-day floor for non-physical. Confirm this revert removes it from EVERY write AND every effective-read: models, presenters, API controllers, settings, product editor, bundle editor, `as_json`, create-service. A leftover `max(7, …)` / `nonzero` clamp on digital is a P1.

4. **Physical vs digital classification.** Enumerate digital, physical, bundle-of-digital, bundle-with-physical, membership/subscription, preorder, gift, coffee, commission, call. The option must be available wherever it was before #7286. A mixed bundle treated as digital-only (or vice versa) is a silent hole.

5. **API + editor + account-level + product-level + bundle-level share the same allow-list.** `PUT /v2/refund_policy?refund_period=none` and product `none` must succeed again for digital. Check seller settings, product editor, bundle editor, presenter option lists. A UI option with a still-rejected 0 in the write path (or the inverse) is a P1.

6. **#7289 still holds.** Fine print still must not *claim* no-refunds. Restoring the 0-day option must not reopen the fine-print claim hole.

7. **Sibling filters still apply.** Refund / chargeback / revoked / gift / test-purchase / risk-blockable scopes must still bind. Check `Purchase::Blockable` and any short-circuit that keyed on the removed floor.

8. **Help-center / API docs / presenter copy.** Surfaces that still say digital products cannot forbid refunds (the #7286 wording) are now false. Overclaim and underclaim are both findings if a customer or agent would treat them as truth.

9. **Specs are load-bearing.** For each restored example, name the previous-variant mutation that must redden it (0-day rejected for digital; option missing from presenter; snapshot still floors to 7; API rejects `none` for digital). A spec that stays green under that mutation is vacuous.

Do NOT run the test suite. Static review only. Do not modify files. Produce READY-TO-MERGE or CHANGES-REQUIRED with P0/P1 file:line + one-line fix.
