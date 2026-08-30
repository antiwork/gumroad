# Domain lens: discounted direct-listed Payment Element amount vs charge

This PR changes how the Stripe Payment Element is mounted for discounted
direct-listed checkouts (tips, excluded tax, shipping). The Element amount
must match the amount Gumroad actually charges. Review as a money-path
shown-one-price-charged-another change.

Numbered checks:

1. **DISPLAY vs CHARGE identity.** Trace `getDirectListedPaymentElementAmount`
   to the server charge / PaymentIntent amount. Do they resolve identically
   for: discounted %, discounted fixed tip, excluded tax, included tax,
   shipping, mixed included+excluded tax, no tip, quantity > 1, multi-product
   carts? A mount that omits a surcharge the charge includes (or vice versa)
   is P0/P1.

2. **Preference chain order is untested until BOTH candidates exist.**
   `listedChargePriceCents ?? listedPriceCents ?? (single ? baseAmount : product.price)`.
   Demand an example where listedChargePriceCents and listedPriceCents
   DIVERGE (this PR's whole point) AND an example where listedChargePriceCents
   is absent so the old listedPriceCents fallback still holds. An inversion
   mutant (`listedPriceCents ?? listedChargePriceCents`) must redden a named
   example. Whole-file revert is not that proof.

3. **Fail-open when the rate is missing.** `listedRate != null ? Math.round(tax_cents * listedRate) : 0`
   silently drops excluded tax/shipping from the Element if
   `listedCurrencyExchangeRate` is unset. Is that reachable on the live
   checkout path after Show.tsx always sets `item.product.exchange_rate`?
   If any product can lack it (USD-listed, missing exchange_rate, mixed
   currencies), the Element under-mounts vs the charge. State whether
   returning 0 is fail-open undercharge-consent or correct.

4. **Which product's rate?** `state.products.find((p) => p.listedCurrencyExchangeRate != null)`.
   First-with-a-rate wins for converting cart-level USD tax/shipping.
   Multi-product / mixed-rate carts: is that the same rate the charge uses?
   Single-product CAD fixtures cannot see this.

5. **Included tax must not be double-added.** `tax_cents` vs `tax_included_cents`.
   Confirm production charge treats included tax as display-only. The new
   examples include both 100 excluded and 60 included — prove the 60 is NOT
   in 1530/1787, and that a mutant adding `tax_included_cents * listedRate`
   reddens.

6. **Tip allocation currency.** Percentage tip is computed from line prices
   already in listed currency; fixed tip uses `listedAmount`. Confirm
   `getTipValues` / equivalent is the same function the summary uses, and
   that a discounted % tip is taken on the POST-discount listed amount
   (1200), not listedPriceCents (1500) or USD subtotal (900). Arithmetic:
   1200 + round(1200*0.15) + round(100*1.5) = 1200+180+150 = 1530. If the
   charge uses a different tip base, this is the bug.

7. **Rounding.** `Math.round(usd * rate)` per surcharge vs summing already-
   rounded listed lines. Does the server round the same way (per-line vs
   on the total)? Off-by-one on tax/shipping is a consent mismatch.

8. **`surcharges.type !== "loaded" => null`.** New early return. What does
   the mount do with null — skip mount, keep previous amount, fall back to
   USD? A flicker/remount to the wrong currency while surcharges load is
   in scope. Check callers of `getStripePaymentElementAmount`.

9. **Show.tsx field semantics.** `listedPriceCents: item.price * item.quantity`
   (pre-discount listed) vs `listedChargePriceCents: price` (post-discount).
   Confirm `price` here is listed-currency post-discount, not USD. Quantity:
   is `price` already * quantity? A quantity-2 discounted line that stores
   unit price in `listedChargePriceCents` under-mounts.

10. **Shipping carts.** Existing example remounts shipping carts in USD.
    Adding shipping * listedRate into the listed-currency Element must not
    re-enable listed-currency mount for shipping carts the USD remount is
    supposed to catch.

11. **Self-fulfilling tests.** The new examples hard-code 1530 and 1787 —
    good. Confirm they would go red if listedChargePriceCents were ignored
    (use listedPriceCents 1500 instead). A mutant deleting the tax/shipping
    addends must fail at least one new example. Report which.

12. **Comment claims.** Comments on the new fields are review surface. Verify
    `listedChargePriceCents` is actually "the post-discount amount the
    listed-currency charge will collect for this line today" by reading the
    writer in Show.tsx and the charge path — do not trust the identifier.
