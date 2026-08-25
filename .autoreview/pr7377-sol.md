Adversarial review of a payout-cohort query change. Hunt:

1. Cohort drift vs old `User.holding_balance.where("json_data->'$.payout_frequency' = 'daily'")`. Same sellers must qualify. `->` vs `->>`, bind vs literal, default weekly users with no JSON key, deleted users, SUM > 0 vs HAVING SUM(balances.amount_cents) > 0.

2. Empty daily set / empty holding set: must not pay anyone.

3. Weekly holders with large unpaid balances must stay out of the SUM IN-list.

4. This must not change Payment creation, is_user_payable, or enqueue args besides the user relation.

5. Specs: is the `user_id IN` assertion load-bearing? Vacuous SQL greps?

6. Comment claims: "~hours" vs measured 60 min; do not treat comments as proof.

Payout money-path. P0/P1 only unless a cohort-drift bug is P0.
