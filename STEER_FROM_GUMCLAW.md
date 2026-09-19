# STEER_FROM_GUMCLAW — gp#2801 / PR #7814 (Greptile review at bfa813a)

## ⛔ CORRECTION (read before you commit P1 #1)

Your in-worktree shape

```ts
: (stripePaymentElementConfig?.stripe_link_enabled ?? true);
```

does **not** close the leak. `stripePaymentElementConfig` is `usesPaymentElement ? elements_options : null`
(line 713), and `usesPaymentElement` is exactly what goes **false** in the leaking case (surcharge
reload below Stripe's minimum, free-trial/preorder, ineligible SETUP mode — payment.ts:576-593), so
`stripePaymentElementConfig` is null there and `?? true` puts Link back on. Read the flag straight off
the integration's own config — do not route it through `stripePaymentElementConfig`:

```ts
const cardElementLinkEnabled =
  state.checkoutPayment.integration === "card_element"
    ? state.checkoutPayment.stripe_link_enabled
    : state.checkoutPayment.elements_options.stripe_link_enabled;
```

Both element configs carry `stripe_link_enabled` (payment.ts:61, :98), so this narrows with no cast
and no `??`. Also re-pin `PaymentForm.test.tsx:941` (details below) — with your current shape that
test's `enableLink === true` assertion and the fixed code disagree.

---

Read this file at your next tree listing. A sibling session handled the Greptile
`issue_comment` (5742550058) and did NOT push anything — this branch is yours.

Greptile posted two P1s. Both mechanisms were verified against this branch's code and
both are REAL. Fix them here; do not wait for another review round.

## P1 #1 — Link comes back on the CardElement fallback (PaymentForm.tsx:717-718)

Current:

```ts
const cardElementLinkEnabled =
  state.checkoutPayment.integration === "card_element" ? state.checkoutPayment.stripe_link_enabled : true;
```

Why `: true` is wrong. `stripePaymentElementConfig = usesPaymentElement ? elements_options : null`
(line 713) and `usesPaymentElement` comes from `canUseStripePaymentElement` /
`canUseStripePaymentElementClientConfirm` (payment.ts:576, :616), which return **false in the
browser** while `integration` is still `payment_element` / `payment_element_client_confirm`:

- a surcharge reload dropping `getChargeTodayPrice` below
  `STRIPE_PAYMENT_ELEMENT_MINIMUM_USD_CHARGE_CENTS` (payment.ts:585-589),
- free-trial / preorder carts (payment.ts:592),
- an ineligible SETUP-mode cart (payment.ts:581-583).

In those cases `stripePaymentElementConfig` is null, the ternary at line 1138 renders
`CreditCardInput` — which mounts a live `CardElement` (`CreditCardInput.tsx:70-83`) with
`disableLink: !enableLink` — and `cardElementLinkEnabled` is hardcoded `true`, so Link's
save-info block renders even when every seller in the cart switched Link off
(`elements_options.stripe_link_enabled === false`). The only other non-`card_element` path
into `CreditCardInput` is the saved-card branch, and that one renders no `CardElement`
(`CreditCardInput.tsx:62-67`), so the flag is irrelevant there.

Fix — read the flag from the config the lane actually has:

```ts
const cardElementLinkEnabled =
  state.checkoutPayment.integration === "card_element"
    ? state.checkoutPayment.stripe_link_enabled
    : state.checkoutPayment.elements_options.stripe_link_enabled;
```

Both element configs carry the field (`payment.ts:61` for `PaymentElementConfig`,
`payment.ts:98` for `PaymentElementClientConfirmConfig`), so the false branch narrows
without a cast. Note the old comment at 714-716 ("Lanes with no card_element config … keep
Link on, as they always have") is what encoded the bug — rewrite it to say the fallback
lanes take the element config's own flag.

Its test encodes the same bug and must change with it: `PaymentForm.test.tsx:941`
("leaves Link on the card fields for a lane with no card_element config") builds a
client_confirm config with `stripe_link_enabled: false` **and** `usingSavedCard: true`, and
asserts `enableLink === true`. Re-pin it as the seller's setting being honored on the
fallback card fields (drop `usingSavedCard: true` so a `CardElement` actually mounts, keep
`stripe_link_enabled: false`, assert `false`). Leaving that assertion as-is will keep the
leak green.

## P1 #2 — PayPal's funding decision is frozen at the cart it mounted with (PaymentForm.tsx:1424-1441)

Verified premise, not speculation: `state.products` is reducer state that changes in place
without remounting `PaymentForm` (`<PaymentForm />` at `index.tsx:797` has no key).
`acceptOffer` dispatches `update-products` (`Show.tsx:363-392`, reducer case at
`payment.ts:1688`) — the codebase comment there says "Accepting a cross-sell updates the
products mid-pipeline on purpose". `usePayPalImplementation`'s `useRunOnce` captured
`state` on its first render, so `cardFundingDisabled` is ANDed over the mount-time cart for
the rest of the page session.

Consequence: open the PayPal lane on a mixed cart (no `disableFunding`) and accept a
cross-sell that leaves every seller opted out — the card button stays visible although the
whole cart asked for it off. The reverse ordering over-hides the button for a buyer. Either
way the seller-complete aggregation and the rendered buttons disagree until a reload.

Traps for whichever shape you pick:

- `@paypal/paypal-js` 8.1.2 `findScript` only reuses a script tag whose data-attributes
  match exactly; a second `loadScript` with different `disableFunding` injects a **new**
  script tag. So "re-run `loadScript` with the new cart" is not by itself a fix.
- `NativePayPal` also builds its `Buttons` inside a `useRunOnce` from the namespace captured
  at mount, so re-running the load without re-creating the buttons changes nothing visible.
- Buyer's in-flight session: only re-decide while the pipeline is `input` (same guard the
  `update-checkout-payment` case uses at `payment.ts:1727-1736`).

Leading candidate: derive the aggregation where the cart is known and key the PayPal lane on
the resolved decision so the hook and its `Buttons` are rebuilt when the cart edit flips it,
gated on `state.status.type === "input"`. Pick the shape you can actually exercise in a
vitest; say in the PR body which one you chose and why.

## Also

- CI on the run for bfa813a is red on `Lint JS/TS` (step `Run npm run lint-fast`) and
  `Compute relevant specs`; logs become available when the run finishes. Clear them in this
  same branch.
- Keep the reply to the review threads to ONE comment when the fixes are pushed (rule: one
  gumclaw comment while no human has replied), and re-pin the panel verdict to the new head —
  a push invalidates `Premerge review: clean @ <sha>`.
