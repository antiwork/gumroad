# Root cause: buyer-currency quote token mismatch (CAD shown, USD charged)

## Status
- Server-side fail-closed: DONE (bf5415048) — orders#prepare rejects buyer_currency_quote tokens on the client-confirm lane.
- Client-side leg: this doc + guard + specs (this branch).

## The divergence path (pinned)

The quote token submitted with the purchase is read from `state.surcharges` at payload-build
time (`pages/Checkout/Show.tsx:394-397` → `buyerCurrencyDisplay.ts:38`), while the totals the
buyer confirmed were rendered from whatever `state.surcharges` held when they clicked Pay.
Nothing pins those two reads to the same quote:

1. **`offer`/`validate` never check `state.surcharges.type`** (`payment.ts:594-603`). The only
   protection is `isSubmitDisabled` (`payment.ts:394-397`), which is a *render-time* button
   `disabled` attribute. A total-affecting `set-value` (e.g. tip change) synchronously flips
   surcharges to `pending` (`payment.ts:561-576`), but a Pay click dispatched in the same
   event-loop turn / before React re-renders the disabled button — or any dispatch path that
   isn't the gated button (Enter key, wallet flows via `PaymentForm.tsx:505/518/1106/1269`,
   `dispatch({type:"validate"})` from the cross-sell offer pipeline in `Show.tsx:242/292`) —
   sails straight through `offer → offering → validating → starting → captcha → finished`.

2. **A mid-flight invalidation does not cancel the in-progress payment.** The `set-value`
   invalidation branch (`payment.ts:561-576`) runs regardless of `state.status.type`. Once
   status has left `input`, a debounced tax recompute / tip change / cart edit landing between
   `validate` and payload build silently swaps `state.surcharges` under the purchase. By the
   time `pay()` runs (`Show.tsx:342`, gated only on `status.type === "finished"` — and reCAPTCHA
   adds real wall-clock time here), `state.surcharges` is either:
   - `pending`/`loading` → `getCheckoutBuyerCurrencyQuoteToken` gets `null` → **no token
     submitted → server charges canonical USD while the buyer confirmed CAD totals** (the
     observed bug), or
   - `loaded` with a *different* quote than the one the Payment Element was mounted with →
     token amount ≠ confirmed amount (the mismatch PR-1's server fail-safe now catches).

Concrete repro shape: buyer changes tip and clicks Pay inside the 300ms debounce window
(`payment.ts:718-734`). The tip `set-value` marks surcharges `pending`; the click's `offer`
proceeds anyway; the refetch resolves (or doesn't) while the status pipeline is running.

## Invalidation gap (proven)

`zipCode` changes only invalidate surcharges when `country === "US" && length === 5`
(`payment.ts:564-567`). But the server uses the postal code for US tax whenever country is US —
`SalesTaxCalculator` derives the taxable state from it (`app/business/sales_tax/sales_tax_calculator.rb:17-18`)
and passes it as the TaxJar destination zip (`:67`). So editing a loaded 5-digit zip down to 4
digits (or clearing it) leaves a stale quote computed for the old zip, while the purchase
payload submits the *current* `state.zipCode` (`Show.tsx:365`) — the server recomputes tax from
the submitted zip at charge time and the charged total diverges from the displayed one.
Fix: invalidate on **any** US zip change; the 300ms debounce already absorbs keystrokes.
(Non-US/non-CA postal codes and `state` values are ignored by the server tax path — no trigger
needed there. CA `state` trigger already exists.)

## Fix (this branch)

In `reduceCheckoutState` (`payment.ts`):
1. `offer` and `validate` refuse while `state.surcharges.type !== "loaded"` — status returns to
   `input` so the pending refetch completes and the buyer can retry. This closes every dispatch
   path, not just the rendered button.
2. When a `set-value` invalidates surcharges while `status.type !== "input"`, the in-progress
   payment is cancelled back to `input` — the totals the pipeline was confirming are no longer
   the totals that will be charged.
3. US zip invalidation drops the `length === 5` condition.

Together with bf5415048 (server rejects tokens on the client-confirm lane), the token submitted
can only ever be the quote whose totals were on screen at submit time.

## Test results

`npx vitest run app/javascript/components/Checkout/payment.test.ts`
→ **78 tests passed, 0 failed** (12 new: refetch-invalidation triggers incl. the US-zip gap,
offer/validate refusal while pending/loading/error, cancel-back-to-input on mid-flight
invalidation, and non-total-affecting changes not disturbing state).

Full Checkout suite (`npx vitest run app/javascript/components/Checkout/`): 6 files /
128 tests passed. (PaymentElementInput.test.tsx couldn't load under the symlinked
~/code/gumroad/node_modules because this branch adds happy-dom/@testing-library to
package.json which aren't installed there — an environment gap, not a failure.)
