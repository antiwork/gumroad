# Domain lens: digital products can no longer use a 0-day / "no refunds" policy

This PR floors non-physical refund policies from 0 days to 7 days. Physical products may still forbid refunds. New purchases snapshot the effective period; existing purchase snapshots stay as stored. Public API rejects `none` except for physical products.

Review as a money-path eligibility widening (more buyers can request refunds). Numbered checks:

1. **Money-repricing / refund-eligibility sweep.** Grep every caller of `effective_max_refund_period_in_days`, `max_refund_period_in_days`, `refund_policy`, `within_refund_period?`, and the purchase snapshot writer. For each call site: does it set a PRICE, decide whether a refund is allowed, or render a period? Confirm DISPLAY and ENFORCEMENT resolve identically for digital products whose stored policy is still 0. A 7-day receipt with a 0-day refund gate (or the inverse) is a P0/P1.

2. **Where the floor is applied vs where the snapshot is written.** Purchase#create snapshots the period. Existing purchases keep the old snapshot. Confirm refund-request time uses the SNAPSHOT, not a live recompute that would silently reopen already-closed 0-day sales — or, if live recompute is intended, that it is stated and tested. Name which path is live.

3. **Physical vs digital classification completeness.** Enumerate every product shape: digital, physical, bundle-of-digital, bundle-with-physical, coffee/membership/subscription, preorder, gift, coffee, commission, call. A "not physical" floor that treats a mixed bundle as physical (or vice versa) is a silent hole. Demand the predicate used (`native_type`, `is_physical`, bundle contents) and whether ANY member being physical is enough.

4. **API + editor + account-level + product-level + bundle-level all share the same floor.** PUT `/v2/refund_policy` rejects `none`; PUT/POST `/v2/products` rejects `none` unless physical. Check seller settings, product editor, bundle editor, presenter option lists, and `as_json`. A dropped option in the UI with a still-accepted 0 in the write path (or the inverse) is a P1.

5. **Abuse / seller-circumvention.** Can a seller still persist 0 via: raw API, product copy, import, unpublished draft then publish, switching native_type physical→digital after setting 0, account-level 0 inherited by a new digital product, or a stored 0 that is never rewritten? The floor must apply at READ/EFFECTIVE time, not only at the last write.

6. **Sibling filters still apply.** Refund / chargeback / revoked / gift / test-purchase / risk-blockable scopes must still bind the newly-eligible 7-day digital purchases. Check `Purchase::Blockable` and any "no refunds" short-circuit that keyed on period==0.

7. **Help-center / API docs / presenter copy reach claims.** Enumerate every surface that still says sellers can forbid refunds on digital goods. Overclaim and underclaim are both findings if a customer or agent would treat them as truth.

8. **Specs are load-bearing.** For each new example, name the previous-variant mutation that must redden it (floor deleted; floor applied to physical; snapshot still writes 0; API accepts `none` for digital). A spec that stays green under that mutation is vacuous.

Do NOT run the test suite. Static review only. Do not modify files. Produce READY-TO-MERGE or CHANGES-REQUIRED with P0/P1 file:line + one-line fix.
