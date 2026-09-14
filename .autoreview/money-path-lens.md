# Domain lens: buyer-currency quotes for tipped non-USD listings (gumroad#7367)

THIS diff (origin/main...HEAD) lets the buyer-currency quote lane serve tipped
non-USD-listed products. Quote tokens sign per-line canonical
price/tip/tax/shipping components; purchase creation reuses those signed
components when submit-time economics still match within
`Purchase::BUYER_CURRENCY_QUOTE_ROUNDING_SLACK_CENTS` (5).

HEAD is `cc10c0b710` ("Fail closed on stale quote components; skip PayPal
overwrite"). Do NOT review an admin-UI removal, refund-policy floor, or
merchant-account provisioning. Grade THIS checkout/charge money path.

Files: `app/models/purchase.rb`, `app/services/checkout/buyer_currency_quote.rb`,
`app/services/purchase/create_service.rb`, `app/services/order/create_service.rb`,
`app/controllers/customer_surcharge_controller.rb`, plus matching specs.

## Prior findings to grade at THIS head (RESOLVED / STILL-OPEN / REGRESSED)

At `0ea07eb345` a Codex panel filed two P1s. `cc10c0b710` claims to fix both.
For each, say RESOLVED / STILL-OPEN / REGRESSED with the current file:line:

1. **Fail-open on component mismatch** (`purchase.rb` apply path). Previous
   head returned from the overwrite when tip-presence or per-component slack
   failed, then charged the unsigned split. `verify!` only compares line
   totals, so a same-total remapped price/tip/tax split still paid. HEAD
   calls `reject_stale_buyer_currency_quote_components!` (quote-invalid)
   instead of returning. Does a same-total remapped split now fail closed?
   Does `process_without_charging!` stop after that error?

2. **Authoritative components on PayPal** (`create_service.rb`). Previous
   head attached signed components to every token-bearing purchase. PayPal
   discards the token before `verify!`. HEAD skips attach unless
   `buyer_currency_quote_components_verified_path?` (no paypal_order_id /
   billing_agreement_id; chargeable blank or Stripe). Combined-charge
   Stripe still attaches (chargeable often blank). Confirm a PayPal
   chargeable cannot overwrite the USD split, and a leftover token cannot
   fail a PayPal payment.

Also re-check earlier (claimed-fixed) findings so they have not regressed:
- tip presence vs rounding slack (0↔N when N ≤ 5)
- UID vs line_index identity (`equal?` vs `==`)
- bind lookup to signed permalink
- apply signed split even when submit-time tip is 0 (happy path)
- per-component (not only aggregate) slack
- unbound identifier now fails closed (`CANONICAL_COMPONENTS_UNBOUND`)
  rather than silently skipping

## Numbered hunt list

1. **Money-repricing sweep.** Grep every caller of `canonical_components_hint`,
   `apply_buyer_currency_quote_canonical_components!`, `buyer_currency_quote_canonical_components`,
   and `Checkout::BuyerCurrencyQuote.verify!`. Which callers set a PRICE or move
   MONEY? Display path and charge path must resolve identically.

2. **Fail closed vs leftover PayPal token.** A checkout that switches to PayPal
   after quoting must charge unsigned USD and succeed. A Stripe checkout whose
   signed and submitted components disagree must not charge.

3. **Per-component slack is 5 independent allowances.** Five components each
   allowed ±5c can sum to ±25c unless the extra sum check is load-bearing.

4. **Submitted price reconstruction.** Confirm the inverse matches how
   `prepare_for_charge!` assembled `price_cents`.

5. **UID / line_index / permalink namespace.** Unbound on a token that has
   components must fail closed on the Stripe path only.

6. **verify! vs apply overwrite.** After a successful apply, totals match the
   token by construction. The independent check is the pre-apply slack
   agreement. If that agreement fails, the charge must not proceed.

7. **Hostile client values.** Quantity, variant, offer code, shipping, tip,
   uid, line_index, permalink swap, expired token, remapped largest-remainder
   cent. Each must refuse or take the pre-#7367 path.

8. **Specs load-bearing?** Previous-variant mutants: (a) restore silent
   `return` on mismatch; (b) drop the PayPal/processor attach gate;
   (c) treat `CANONICAL_COMPONENTS_UNBOUND` as nil. Name which new example
   dies for each.

Static review only. Do not run the suite. Do not modify files. Final message
must be READY-TO-MERGE or CHANGES-REQUIRED with P1/P2 file:line + one-line fix.
P1 = merge-blocking money incorrectness or an unpinned money invariant.
