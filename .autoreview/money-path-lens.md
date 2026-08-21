# Domain lens: nil flow_of_funds USD synthesis on Purchase#load_flow_of_funds

This PR widens a money-path fallback. `load_flow_of_funds` used to synthesize a USD
`FlowOfFunds` from `total_transaction_cents` only for non-Stripe processors. It now
synthesizes for ANY non-presentment purchase (`unless buyer_presentment?`), and for
combined charges it synthesizes from `charge.amount_cents` (the shared charge) before
splitting the purchase share.

Review as an adversarial pre-merge money-path review. Numbered checks:

1. **Whose cents?** For `FlowOfFunds.build_simple_flow_of_funds(Currency::USD, flow_amount_cents)`,
   confirm `flow_amount_cents` is the amount that actually moved, not a seller/Gumroad cut
   and not a presentment amount. Read where `total_transaction_cents` and `charge.amount_cents`
   are written. A simple flow that also sets `gumroad_amount` equal to the full total is a
   polarity bug if later code books Gumroad's share from that field — grep every reader of
   `flow_of_funds.gumroad_amount` / `issued_amount` / `settled_amount` on the mark-successful
   / increment-seller-balance path.

2. **Combined-charge amount source.** The new line uses
   `is_part_of_combined_charge? ? charge.amount_cents : self.total_transaction_cents`.
   Confirm `charge` is the combined Charge row (not a Stripe Charge wrapper) and is loaded
   at this call site. If `charge` is nil on a purchase flagged `is_part_of_combined_charge`,
   this is a new NoMethodError replacing the old one. Confirm `build_flow_of_funds_from_combined_charge`
   still splits the purchase share AFTER synthesis and that synthesizing the WHOLE charge
   amount onto `processor_charge.flow_of_funds` cannot double-count when siblings also call
   `load_flow_of_funds`.

3. **`buyer_presentment?` vs the old Stripe-processor guard.** The old guard
   (`StripeChargeProcessor.charge_processor_id != charge_processor_id`) excluded ALL Stripe
   purchases, presentment or not. The new guard includes non-presentment Stripe. Demand:
   (a) the definition of `buyer_presentment?` — association vs flag vs currency mismatch;
   (b) whether a Stripe presentment purchase can have `buyer_presentment?` false (false
   negative ⇒ wrong-currency USD relabel — P0); (c) whether a non-Stripe processor can ever
   be presentment today (false positive would now skip a fallback that used to fire);
   (d) PayPal / Braintree / other processors still get the fallback when not presentment.

4. **`||=` does not overwrite a real flow.** Spec covers a provided CAD flow. Also check
   the inverse: an EMPTY-but-present flow object (zero cents, or a flow whose issued_amount
   is nil) would skip synthesis. Is that possible from `StripeCharge#build_flow_of_funds`?

5. **Reachability.** Trace `load_flow_of_funds` callers. Confirm the GUMROAD-1D9 path
   (`MarkSuccessfulService` → `increment_sellers_balance!` → `flow_of_funds.issued_amount`)
   actually goes through this private method, and that a nil `processor_charge` / missing
   charge wrapper cannot skip it. A green spec that `send`s the private method does not
   prove the production entry point.

6. **Fail-closed vs stranded capture.** The incident: charge captured, purchase marked
   failed, seller unpaid, no refund. Does synthesizing a USD flow on a charge that is
   actually presentment (or whose presentment row is missing) credit the seller the wrong
   amount? Is missing `purchase_presentment` treated as non-presentment (the spec creates
   the association to opt INTO the nil path — so the default factory is the synthesis
   path). If production presentment rows can be missing, this ships the wrong-currency
   bug the comment claims to avoid.

7. **Spec vacuity.** The synthesizing example asserts `gumroad_amount.cents == total_transaction_cents`.
   If `build_simple_flow_of_funds` always copies the same integer into issued/settled/gumroad,
   that assertion cannot distinguish a fee split. Combined-charge example must uniquely die
   if the amount source reverts to `total_transaction_cents`. Presentment example must uniquely
   die if the guard reverts to `if StripeChargeProcessor... != charge_processor_id` OR if
   `unless buyer_presentment?` is deleted. Demand the previous-variant mutant, not deletion.

8. **Does this cover the whole class?** Nil `flow_of_funds` from a missing Stripe balance
   transaction — are there sibling builders (`PaypalCharge`, `BraintreeCharge`, order-level
   combined charges, gift purchases, free purchases, commissions) with the same nil and a
   different loader? If the root cause can be stated without naming Stripe, enumerate every
   processor charge class that can return nil `flow_of_funds`.
