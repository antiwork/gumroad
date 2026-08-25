Adversarial pre-merge review of antiwork/gumroad branch gumclaw/faster-daily-instant-payouts (PR 7377).

Change: `Payouts.create_instant_payouts_for_balances_up_to_date` no longer does `User.holding_balance.where("json_data->'$.payout_frequency' = 'daily'")`. It now loads daily-frequency user ids, then `Balance.unpaid.where(user_id: daily_user_ids).group(:user_id).having("SUM(amount_cents) > 0")`, then `User.where(id: holding_ids)`. Spec listens to `sql.active_record` via `ActiveSupport::Notifications.subscribed` and asserts the SUM query is `user_id IN` the daily holder, not the weekly holder.

This is a LIVE money path: `PerformDailyInstantPayoutsWorker` (`retry: 0`, queue `:critical`) calls it daily at 08:00 UTC. A missed seller is unpaid for the day with no retry. A wrongly included seller can be paid who should not be in this cohort (downstream `is_user_payable` still gates, but enqueue/comment side effects fire).

Numbered hunt (P0/P1 only; READY-TO-MERGE or CHANGES-REQUIRED):

1. COHORT EQUALITY vs the old one-liner. Enumerate every row shape: daily+positive unpaid, daily+zero, daily+negative net unpaid, daily+mixed-sign unpaid rows that SUM>0, weekly+large unpaid, default weekly with no json key, deleted users, users whose only unpaid balances are on a different association than `Balance.unpaid`. `->` vs `->>`, bound `User::PayoutSchedule::DAILY` vs literal `'daily'`. A missed daily seller is P0.

2. Empty daily_user_ids short-circuit vs empty holding_ids: must pass an empty relation, never all users, never User.holding_balance.

3. IN-list / `.ids` blast: `.ids` materializes every daily user (claimed ~261). Confirm no default_scope leak (deleted, suspended) that the OLD `User.holding_balance.where(json…)` would have included or excluded differently. MySQL IN of a few hundred ints is fine; an unbounded `.ids` on the wrong predicate is not.

4. HAVING vs the weekly helper `Payouts.holding_balance_user_ids` (keyset + Ruby `amount_cents > 0`, no HAVING). For this small IN-list, HAVING is the old User.holding_balance semantics — confirm SUM column is the same (`amount_cents` vs `balances.amount_cents`) and `Balance.unpaid` does not join in a way that double-counts.

5. Downstream: `create_instant_payouts_for_balances_up_to_date_for_users` args besides the user relation must be unchanged (`date`, `perform_async: true`, `add_comment: true`). Relation vs Array: old spec stubs `.with(..., [u4], ...)`. Does the new `User.where(id: holding_ids)` change order or identity vs the old holding_balance relation in a way that drops a seller?

6. Spec load-bearing: the SQL grep `/SUM(amount_cents)/` + `` `user_id` IN `` — name any mutation that stays green (drop HAVING, swap to `>= 0`, use `->>`, omit daily filter on the User query, pass User.holding_balance again). Negative-net daily seller has no example. The `subscribed` wrapper must not change what SQL is captured vs a leaky subscribe.

7. Do NOT treat comments ("~hours", "few hundred") as proof. Do not run the test suite. Do not modify files.

Verdict format: READY-TO-MERGE or CHANGES-REQUIRED with P0/P1 file:line + one-line fix.
