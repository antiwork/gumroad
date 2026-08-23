# Domain lens: native PayPal tax-location reconfirm (checkout money path)

This PR changes what happens after native PayPal approval when the PayPal billing country
changes the checkout tax location. Money can be captured on the second click. Review the
FULL three-dot diff vs origin/main, not only the latest lint commit.

Numbered checks (P1 if any fails):

1. **Shown total vs charged total.** After a tax-location change, is capture blocked until
   a fresh tax quote is applied to the displayed total AND the next PayPal approval is
   bound to that quote? A path that captures the first-approval amount after a country
   change, or captures before the quote lands, is a P1.

2. **Same-location must stay the old path.** If PayPal returns the same tax location,
   checkout must proceed without forcing a second click. Mutant: treating every PayPal
   approval as a location change (or never treating any as a change).

3. **Id-namespace / address source.** Confirm the PayPal billing country/state/ZIP the
   reducer compares is the same namespace the tax quote uses. A mismatch makes the
   "reconfirm" a permanent no-op (or a permanent loop).

4. **US ZIP and CA province.** US tax needs ZIP; CA needs province. A country-only compare
   that drops postal/state can charge the wrong intra-country tax. Check both the
   production compare and that each example uniquely kills its mutant.

5. **Second-click is user-visible, not a callback replay.** If tests invoke a retained
   `onApprove` / dispatch `start-payment` without a fresh PayPal button lifecycle, deleting
   `setPaymentMethod(null)` (or the equivalent clear) stays green. Demand an example that
   reddens when the first approved PayPal state is not cleared.

6. **Stale surcharge / in-flight quote.** A tax-location change must abort any in-flight
   surcharge/tax request from the first approval so the second click cannot capture against
   a stale quote.

7. **Wallet/card paths unchanged.** Card and wallet billing-address updates must not take
   the PayPal-only reconfirm branch. A shared `set-value` fallback that re-enters capture
   after a PayPal country change is the original bug.

8. **useMemo context identity.** The latest commit memos `[checkoutState, dispatch]`.
   Confirm this cannot freeze a stale tax location / payment method across the second
   approval (deps must include every value the child reads from context).

9. **Fail closed on missing PayPal address.** If PayPal returns no country, do not capture
   as if the original checkout country were confirmed.

10. **Vacuous specs.** Name any new example that stays green if the production guard is
    deleted or inverted. Those are not coverage.
