Adversarial pre-merge review of gp2181-multi-item-direct-listed-cart @ 69f0f71a5a07f2509bb5b476d9253dcfad77e1fb.

This diff WIDENS a money-path eligibility predicate: checkout's direct-listed-currency Payment Element + charge lane used to require a SINGLE cart item priced in the buyer's currency; it now accepts a MULTI-ITEM cart if every item is uniformly priced in that currency (same listed currency, same exchange rate). Display path (JS) and charge path (Ruby presenter + BuyerCurrencyEligibility) must stay identical.

Do NOT modify any files in the author's tree. Do not push or comment. Report READY-TO-MERGE or CHANGES-REQUIRED with P1/P2/P3, each with file:line + a one-line fix.

Numbered checklist (attack these; a rubber stamp is a failed review):

1. DISPLAY vs CHARGE identity (P1 if they diverge). Walk getCheckoutListedCurrencyDisplay, StripePaymentPresenter#direct_listed_card_shape?, and BuyerCurrencyEligibility's listed-currency-is-buyer-currency branch. For every cart shape (empty, one item, N same-currency, mixed currencies, split exchange rates, tips, shipping, installments, recurrence/UPI, saved card, non-card, multi-seller), say whether DISPLAY would show listed currency AND whether CHARGE would actually charge in it. A shown-listed / charged-USD (or the inverse) is a P1.

2. THE money-repricing / charge-amount sweep. After dropping `items.one?` / `cartItems.length !== 1` / `purchases.one?`, who still assumes one item when summing presentment_amount_cents, converting tax/shipping/tip USD rows, or building the Payment Element amount? Grep presentment_amount, direct_listed, listed_currency, exchange_rate across app/javascript/components/Checkout, app/presenters/checkout, app/services/checkout. A sum that used the first item's rate on a shared USD row is the defect this PR's own comment names — confirm the CHARGE side has the same split-rate fallback, not just the display helper.

3. Multi-seller carts. Presenter now requires EVERY item's seller to have seller_enabled? AND listed_currency_direct_charge_enabled?. Eligibility still calls listed_currency_direct_charge_enabled?(seller) on a SINGULAR seller after removing purchases.one?. If a cart can contain two sellers (one ramped, one not) with the same listed currency, which path wins? Demand the truth table. Same for two sellers both ramped but with different Connect/merchant-account currency support.

4. Completeness of the widened predicate. The JS loop also rejects pay_in_installments, recurrence≠UPI, currency mismatch, rate<=0, split rates. Does the Ruby presenter/eligibility reject the SAME set, or can a two-item installment/subscription cart mount a listed-currency element that charge then rejects (or vice versa)? Enumerate each JS early-return and name its Ruby twin.

5. Specs that would still pass if the production change were reverted. New examples pin "two CAD items mount CAD" and "CAD+USD stays USD". Which example fails if `purchases.one?` / `items.one?` / `cartItems.length !== 1` is put back? If none, the headline widening is untested on that surface. Also: a mixed-currency example that was already true under the old single-item guard is not coverage of the new path. Demand a previous-variant mutant (restore `.one?`) that reddens a NEW example, not deletion of the whole method.

6. Two-candidate currency fields. Purchases have link.price_currency_type (live product) vs purchase.displayed_price_currency_type (charge-time snapshot). The new eligibility example sets both to CAD. A mutant reading the live product currency stays green. Is there an example where they DIVERGE? Same on the presenter: product_currency vs displayed snapshot.

7. Currency scaling. Gumroad's unit_scaling_factor is 1 only for JPY; KRW/TWD are ISO zero-decimal but Gumroad scales by 100. StripeChargeProcessor.charge_minor_units_compatible? plus listedCurrency.subunit_to_unit must not teach the ISO rule. Multi-item summing of presentment_amount_cents: 1500+2500=4000 in the new spec — confirm that is listed minor units, not a mixed-scale sum, and that two JPY items cannot be added as if they were cents.

8. Sibling surfaces still assuming single-item. Grep `items.one?`, `cartItems.length !== 1`, `purchases.one?`, `single-item`, `direct_listed` in app/ and spec/. A comment, Payment Element remount, wallet disable, or analytics event that still says "single-item lane" is either a stale claim (P2) or a live gate the widening forgot (P1).

9. Tips/shipping. JS still returns null when hasTip || hasShipping because "server still mounts product price only". After allowing N items, is that still true, or does a two-item+tip cart now have a server amount that includes tip in listed currency while display stays USD (or the reverse)? Read method_forced_element_currency and the amount builder, do not reason.

10. Feature-flag / ramp blast radius. listed_currency_direct_charge is a per-seller flag. Widening from 1 item to N items on an already-ramped seller is a behavior change for live traffic, not just a new flag. State whether mixed-seller / marketplace carts are reachable in production for this flag's cohort.

11. Self-fulfilling assertions. payment_element_client_confirm_props(currency:, presentment_amount_cents: 4000) — is 4000 independently recomputed from the two product prices, or copied from the presenter's own sum? If the presenter is wrong, does the spec still pass?

12. Vacuous short-circuits. Any new example that never gets past seller_enabled?, geoip, Stripe.api_key, or listed_currency_displayed? does not pin the removed `.one?` clause. Say which values get each new example PAST those guards.

Verdict format: READY-TO-MERGE or CHANGES-REQUIRED. P1 merge-blocking / P2 should-fix / P3 nit. Each finding: file:line + one-line fix. Also list Checked Safe items you actually walked.
