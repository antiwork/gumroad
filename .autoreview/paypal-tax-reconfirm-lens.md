# Domain lens: native PayPal tax-location reapproval (checkout money path)

THIS HEAD is cbf9da7025c10be589ec4f7e43b1cb30a8c9a771.

Money path. Native PayPal approval maps PayPal's billing address onto checkout tax location
(country / US ZIP / CA province) and, on a tax-location change, must abort before capture,
refetch tax, return the buyer to input, and require a second PayPal click. Same-location
approvals must still continue.

Newest commit (cbf9da7025) is a SPEC-ONLY pin after two prior Sol P1s:
- d822749ae8 / 4ffd81d38d Sol P1: PaymentForm.test.tsx replayed the retained
  `buttonsConfig.onApprove` after a manual `start-payment`, so deleting
  `setPaymentMethod(null)` left the suite green.
- cbf9da7025 claims: drive the resume click through `onClick` and add a leftover-token
  case that reddens when that clear is removed.

Production files in the three-dot diff: PaymentForm.tsx, payment.ts, paypal.ts.

## Prior findings to grade at THIS head

1. At b1c2ba88d5 Sol filed: US→DE still passed if the generic `country !== state.country`
   clause was deleted, because `(state.country === "US" && country !== "US")` covered it.
   Non-US→other-non-US (e.g. DE→CA) was unprotected. Later commits added
   `paypalBillingAddressChangesTaxLocation`. Mark RESOLVED / STILL-OPEN / REGRESSED.

2. At 6489290658 / d822749ae8 / 4ffd81d38d Sol filed P1: lifecycle test bypassed the UI
   by manually dispatching `start-payment` and invoking the retained `onApprove`.
   cbf9da7025 claims to fix this. Mark RESOLVED / STILL-OPEN / REGRESSED. Do not re-raise
   verbatim without checking the new harness. Mutate by deleting `setPaymentMethod(null)`
   and name which NEW example reddens.

## Numbered adversarial checklist

1. Preference-chain order is untested until one example has BOTH candidates.
   `paypalBillingStateForCheckout` is `action.state || CA-postal-derive || same-country checkout.state || CA GST fallback || ""`.
   `zipCode` is `action.zipCode || (same country ? checkout.zipCode : "")`.
   Demand an example where BOTH candidates are present; mutation is the INVERSION (B || A).

2. Tax-location predicate completeness vs the tax quote's actual keys (country, state, ZIP, VAT ID).
   The predicate only treats country, US ZIP, and CA province as tax-changing. If another
   country (AU/IN/etc.) taxes by subdivision or postcode, a PayPal address change there
   continues to capture on a stale quote. State membership from the tax-quote code, not memory.

3. Display path vs charge path must resolve identically after a tax-location change.
   A shown-one-price / charged-another is P1.

4. `setPaymentMethod(null)` + `return` after dispatch: confirm this actually prevents native
   onApprove from continuing into billing-agreement / capture. Check whether a later effect
   re-enters and captures anyway.

5. Same-location must reduce to the old continue-to-capture behavior. Empty/missing PayPal
   state or ZIP must not false-positive a tax change.

6. US ZIP / CA province / other-country are independent flags. Truth table + one mutation
   PER clause. Which new example reddens if the US-ZIP clause is deleted? If the CA-province
   clause is deleted? If the country-inequality clause is deleted?

7. Id-namespace / payload fidelity: confirm PayPal billing-agreement response actually has
   `state` (not `state_or_province` / `admin_area_1`). A wrong key makes the CA-province
   fix a no-op.

8. The leftover-token / second-click examples must uniquely kill: (a) keeping the stale
   agreement, (b) capturing on the first onApprove, (c) skipping tax refetch,
   (d) deleting `setPaymentMethod(null)`. Name any mutant that no example catches.

9. Runtime reachability: native PayPal onApprove only, or also Braintree / billing-agreement
   reconnect / saved PayPal?

10. New specs vs production: the latest commit touches only tests. Confirm they pin
    production behavior, not a mock that agrees with itself. Drive-through-onClick is not
    enough if the test still holds a stale callback.

Verdict: READY-TO-MERGE or CHANGES-REQUIRED. P1 merge-blocking / P2 should-fix / P3 nit,
each with file:line and a one-line fix. Grade prior findings first.
