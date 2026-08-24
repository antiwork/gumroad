# Domain lens: buyer-currency quotes for tipped non-USD listings (gumroad#7367)

THIS diff (origin/main...HEAD) lets the buyer-currency quote lane serve tipped
non-USD-listed products. Quote tokens now sign per-line canonical
price/tip/tax/shipping components; purchase creation reuses those signed
components when submit-time economics still match within
`Purchase::BUYER_CURRENCY_QUOTE_ROUNDING_SLACK_CENTS` (5).

HEAD is `0ea07eb345` ("Refuse slack-crossing tip presence and conflicting quote
row ids"). Do NOT review an admin-UI removal, refund-policy floor, or
merchant-account provisioning. Grade THIS checkout/charge money path.

Files: `app/models/purchase.rb`, `app/services/checkout/buyer_currency_quote.rb`,
`app/services/purchase/create_service.rb`, `app/services/order/create_service.rb`,
`app/controllers/customer_surcharge_controller.rb`, plus matching specs.

## Prior findings to grade at THIS head (RESOLVED / STILL-OPEN / REGRESSED)

At `6bbc2d8d16` / `ed92d2aa42` a Codex panel filed two P1s. `0ea07eb345` claims
to fix both. For each, say RESOLVED / STILL-OPEN / REGRESSED with the current
file:line:

1. **Tip presence vs rounding slack** (`purchase.rb` apply path). Slack of 5c
   treated adding/removing a 1–5c tip as rounding, then restored the signed tip
   (or zeroed a new tip) without a matching Tip record. HEAD adds
   `return unless component_tip_cents.positive? == submitted_tip_cents.positive?`
   before per-component slack. Does that close 0↔N tip transitions when N ≤ 5?
   Does `0.positive? == false` treat both nil and 0 as "no tip"? Can a Tip row
   exist with `value_cents: 0` (it must not)?

2. **UID vs line_index identity** (`buyer_currency_quote.rb#canonical_components_hint`).
   HEAD resolves `by_uid` and `by_index` independently and, when both identifiers
   are present, accepts only `by_uid if by_uid && by_index && by_uid.equal?(by_index)`.
   Grade `Object#equal?` (identity) vs `==` (value): two separately found hashes
   that name the same row — is it the same object from one `select`, or could
   equal payloads fail identity? Can a swapped UID still steal a sibling
   permalink-scoped split?

Also re-check earlier (claimed-fixed) findings so they have not regressed:
- bind lookup to signed permalink
- apply signed split even when submit-time tip is 0
- refuse when submit economics diverge from the token
- per-component (not only aggregate) slack

## Numbered hunt list

1. **Money-repricing sweep.** Grep every caller of `canonical_components_hint`,
   `apply_buyer_currency_quote_canonical_components!`, `buyer_currency_quote_canonical_components`,
   and `Checkout::BuyerCurrencyQuote.verify!`. Which callers set a PRICE or move
   MONEY (purchase create, order create, surcharge, subscription renewals,
   preorder/commission later charges)? Display path and charge path must resolve
   identically.

2. **Tip presence / zero transitions.** Independent of (1) above: if signed tip
   is 0 and submitted tip is 1–5 (or the reverse), what persists? Is a Tip row
   created/absent consistently with `value_usd_cents`? `Tip` cannot store
   `value_cents: 0`. A charge that includes a tip with no Tip record (or a Tip
   record whose cents were overwritten to 0) is a P1.

3. **Per-component slack is 5 independent allowances.** Five components each
   allowed ±5c can sum to ±25c unless the extra sum check is load-bearing.
   Mutate mentally: drop the sum check; drop one per-component check; invert
   `<=` to `<`. Which spec reddens for each? Name any mutant nothing catches.

4. **Submitted price reconstruction.**
   `submitted_price_cents = price_cents - submitted_tip_cents - shipping_cents`
   then minus `tax_cents` only if `was_tax_excluded_from_price`. Confirm this
   inverse matches how `prepare_for_charge!` assembled `price_cents` (tip
   included? tax-inclusive listed prices? gumroad tax never in `price_cents`?).
   A wrong inverse makes the new per-component gate either a no-op or a false
   refuse of honest quotes.

5. **UID / line_index / permalink namespace.** Confirm both identifiers are the
   same namespace the quote signed. Repeated permalinks: require UID+index to
   agree when both present. A missing UID on a multi-row permalink must not
   `sole`/first-match a sibling. Grade `equal?` vs `==` on the two finds.

6. **PayPal / non-Stripe.** Rate hint is the only bound for PayPal (token
   discarded before `verify!`). Does applying signed canonical components on a
   PayPal purchase charge a locked USD split the processor never verifies?
   Fail closed or skip the overwrite on processors that never `verify!`.

7. **Currency unit lens.** Slack is 5 *canonical USD cents*. Confirm it is never
   applied to listed JPY/KRW/TWD minor units. Gumroad scales every currency by
   100 except `jpy`. Do not teach ISO zero-decimal rules. Specs that set
   `link.price_currency_type` and `displayed_price_currency_type` to the same
   value cannot kill a wrong-source mutant.

8. **verify! vs apply overwrite.** After apply, `total_transaction_cents`
   becomes the signed total. Does `verify!` then tautologically pass because
   both sides now read the overwritten purchase? The token must still be checked
   against an independent recomputation, or apply+verify is `x == x`.

9. **Hostile client values.** Quantity, variant, offer code, shipping address,
   tip, uid, line_index, permalink swap, expired token, mixed USD+non-USD cart,
   remapped largest-remainder cent. Each must refuse or take the pre-#7367
   path — never silently charge the old quote for a new cart.

10. **Specs load-bearing?** Revert-to-previous-variant, not deletion: (a) restore
    the old tip+adjusted-total pair of checks; (b) restore UID-then-index
    fallback; (c) drop the tip-presence equality guard. Name which new
    example dies for each. Always-dies-alongside = rename, not coverage.

Static review only. Do not run the suite. Do not modify files. Final message
must be READY-TO-MERGE or CHANGES-REQUIRED with P1/P2 file:line + one-line fix.
P1 = merge-blocking money incorrectness or an unpinned money invariant.
