# Domain lens: disable license keys on a full refund

This diff adds `Purchase#disable_attached_license_if_fully_refunded!` and calls it from
refund bookkeeping so `/v2/licenses/verify` stops accepting a key after a full refund.
Money/risk: refunds + entitlement revocation. Review with these numbered checks.

1. **Call-site completeness.** The helper only runs where this PR calls it
   (`refund_purchase!`, `refund_partial_purchase!`, `refund_for_fraud!`,
   `mark_giftee_purchase_as_refunded`, `mark_product_purchases_as_refunded!`).
   Enumerate EVERY path that sets `stripe_refunded = true` (or `update!(stripe_refunded: true)`)
   in `app/`/`lib/`. Any path that marks a purchase fully refunded without the helper is
   a P1 if that purchase can have a live license. Name each miss with file:line.

2. **Raise after Stripe already refunded.** `disable!` is `save!` inside the refund
   transaction, AFTER `ChargeProcessor.refund!` succeeded. If `disable!` raises, does the
   DB roll back `stripe_refunded` while the processor already moved money? Is that worse
   than leaving the key live? Grade it; do not waive because the surrounding method already
   had post-processor writes.

3. **Gift polarity.** Gifter refunds now disable the *giftee* license via
   `linked_license` / `mark_giftee_purchase_as_refunded`. Confirm: (a) gifter purchases
   have no own license, (b) refunding the giftee row itself also disables, (c) a partial
   gifter refund does not disable. A swapped gifter/giftee target is a P1.

4. **Recurring / membership.** Ordinary renewal refund must NOT disable
   `subscription.original_purchase.license`. Fraud refund of a renewal MUST. Probe
   `is_recurring_subscription_charge` — is it true only for renewals, or also the original?
   If the original is flagged recurring, the non-fraud branch never disables it.

5. **Chargeback / dispute.** Does a chargeback mark the purchase refunded without
   going through these hooks? If `/v2/licenses/verify` still accepts the key after a
   lost dispute, say whether that is in this PR's stated class or a sibling follow-up.

6. **Comment vs verify API.** The comment claims `/v2/licenses/verify` rejects
   `disabled?` but not `stripe_refunded`. Grep the verify endpoint and confirm both
   halves. A false rationale in the comment is itself a finding (sweep PR body/commit
   too if they repeat it).

7. **Idempotency / already-disabled / already-refunded.** `refund_for_fraud!` calls
   the helper even when `refund_and_save!` no-ops. Does a second ordinary refund also
   no-op safely? Does `disable!` on an already-disabled license matter? Does
   `stripe_refunded?` after `reload.lock!` see in-memory assignment or only committed state?

8. **Specs: which mutant dies uniquely?** For each new example, name a one-line
   mutant that ONLY that example catches. Demand the previous-variant mutants:
   (a) drop the `return unless stripe_refunded?` guard, (b) drop the
   `return unless for_fraud` on renewals, (c) always use `linked_license` (never original),
   (d) skip the giftee/product-purchase call sites, (e) call `disable!` on partials.
   Any mutant the suite stays green under is a coverage miss (P1 if it is a money/entitlement
   guard).

9. **Combined charges / bundle product purchases.** `mark_product_purchases_as_refunded!`
   now disables each child's license on full refund. Confirm a child can have its own
   license, and that a partial combined-charge refund does not disable any child.

10. **Transaction visibility.** `disable!` runs after `save!` of the purchase. License
    `after_commit` reindexes the purchase. Any deadlock / lock-order inversion vs the
    purchase `lock!` already held? Read `License#disable!` and `update_purchase_search_index`.
