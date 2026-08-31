# Domain lens: discounted direct-listed Payment Element amount vs charge

This diff is a money-path checkout fix: discounted direct-listed Stripe Payment Element
mounts must use the same listed-currency total the later charge uses (post-discount
listed lines, listed tip, per-line tax/shipping, signed page FX rate).

Review ONLY in-scope blockers (P0/P1). Re-grade these prior P1s against THIS head:

1. **Signed page rate vs live surcharge rate.** Element tax/shipping conversion must use
   the rate signed into `payment_method_list_token`, not a live `get_rate` / product
   exchange_rate that can refresh between page render and mount. If the surcharge
   endpoint still converts with a different rate than `Purchase::CreateService`, that is
   a consent mismatch. Fail closed and remount rather than mixing rates.

2. **Client-supplied listed totals.** If `listed_price_cents` / `listed_tip_cents` are
   request-controlled, are they validated against the cart (permalink, quantity,
   discount, tip) before being returned as server-owned allocations the browser trusts
   for the Element amount? A stale or hostile payload that shrinks the mounted amount
   below the later charge is a P1.

3. **Token replay / cart fingerprint.** Does the signed FX token bind price-affecting
   cart contents (permalinks, quantities, prices, discounts, tips), or only payment
   method types + seller IDs + currency? A still-valid token from another cart with the
   same seller set is a P1 if charge conversion then uses a different rate than the
   mounted cart.

4. **Fail closed on missing per-line allocations.** Aggregate tax/shipping conversion
   can disagree with per-line rounded charge conversion (two 1-cent lines at 1.5). If
   the client still falls back to aggregate conversion when allocations are missing,
   that is a P1 for multi-line excluded-tax/shipping direct-listed carts.

5. **Tip base.** Percentage and fixed tips must be applied to the post-discount listed
   amount, not the undiscounted subtotal. Display and charge must resolve identically.

6. **Included vs excluded tax.** Included tax is display-only and must not be
   double-added into the Element amount. Excluded tax must be in the Element amount
   whenever it is in the charge.

7. **Currency scaling.** Gumroad scales every currency by 100 except JPY
   (`unit_scaling_factor` / `single_unit`). Do not apply ISO zero-decimal rules to
   KRW/TWD. Conversion helpers used on client fallback AND server allocation must agree.

8. **Whose money / which rate.** For every `x - y` or `x * rate` on this path, find
   where each operand is WRITTEN. Do not infer from identifier names. Page-issued
   signed rate vs live quote vs product.exchange_rate vs buyer-currency quote are
   different sources.

9. **Load-bearing specs.** Name which example reddens if (a) allocation rate is swapped
   back to live get_rate, (b) hostile listed_price_cents is accepted, (c) token is
   reused on a different cart, (d) aggregate fallback is restored. "None" means the
   headline change is untested.

Do not flag process/QA/screenshot gaps. Do not run the test suite. Static review only.
Verdict must be READY-TO-MERGE or CHANGES-REQUIRED with [P1] file:line findings.
