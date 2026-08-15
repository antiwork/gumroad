Adversarial pre-merge review for antiwork/gumroad#7229 (checkout buyer currency picker) at 15c71d2176f952611e48151f968e59a6a61d22cd.

This is a MONEY path. Charge-time eligibility, quote tokens, presentment currency, and checkout payment submission are in scope. Prior clean marker was at 9f8152a29f; this head only recaptured a QA still, but review the FULL three-dot diff vs origin/main, not just the last commit.

## Currency / minor-unit lenses (must apply)

1. Docs/comments describing a unit rule must match `unit_scaling_factor` / `single_unit` in `config/currencies.json`. Gumroad scales every currency by 100 except `jpy`. KRW and TWD are ISO/Stripe zero-decimal but Gumroad still uses 100. Flag any comment/spec/UI that teaches the ISO zero-decimal rule.
2. Two-candidate sources: `link.price_currency_type` vs `purchase.displayed_price_currency_type` / quoted vs GeoIP vs selected cookie vs `?currency=`. A fixture that sets both the same cannot kill a wrong-source mutant. Demand a spec where they DIVERGE.
3. Adjacent-currency ambiguity: when a cart carries detected, selected, listed, and quoted currencies, check which one charge, display, wallet fallback, and save-card each read — and that display and charge resolve identically.

## Numbered checklist

1. **Charge vs display identity.** Walk every call site of the quote / selected currency / `BuyerCurrencyEligibility#decision` / `BuyerCurrencyQuote`. Does any money-moving path (purchase create, Payment Element confirm, wallet, save-card) charge a different currency than the summary shows? Shown-one charged-another is P1.
2. **Eligibility key vs token.** `quoted_currency_hint` must be what `verify!` checks. GeoIP fallback only when the token is absent/tampered — NEVER when the buyer selected a different currency than GeoIP. A GBP token from a CAD IP must stay GBP.
3. **Hostile param types.** `params[:buyer_currency_quote]` is attacker-controlled. Array/Hash/Parameters must not 500 (`NoMethodError` on `valid_encoding?`). Must fall back to GeoIP. Prior finding at `quoted_currency_hint` rescue list — re-verify whether a non-string still escapes.
4. **Wallet / save-card fallbacks.** Apple Pay / Google Pay / save-card must drop the buyer-currency quote and settle in canonical currency. Inverse: unchecking save-card must restore the quoted currency. A leftover quote token on a wallet charge is P1.
5. **Unavailable preference.** Cookie/`?currency=` for a currency not in the surcharge offer must not pin an unquotable currency. Confirm the replacement is requested AND stored (not just displayed).
6. **Listed-currency carts.** Direct listed-currency Payment Element lanes must hide the picker and keep the listed currency. Mutating that hide-guard away must redden a spec.
7. **Zero-decimal / whole-amount labels.** KRW/TWD vs JPY. Picker labels and reminted amounts must follow Gumroad scaling, not ISO. Check `config/currencies.json` vs display helpers.
8. **Cookie + query precedence.** `?currency=usd` vs remembered cookie vs detected. State the order; demand a spec with BOTH candidates present (preference-chain inversion mutant).
9. **Token mint vs charge-time remint.** Changing the picker remints the quote. Stale token from a previous selection must not be accepted for a new cart/currency. Signature-checked hint only.
10. **Fail-closed vs fail-open.** Tampered token, expired quote, FX timeout: which way does charge go? A fail-open that charges the wrong currency is P1; a 500 on hostile input is also P1.
11. **New specs load-bearing.** Which example fails if eligibility reads GeoIP again? Which fails if `quoted_currency_hint` accepts non-strings? Name them.
12. **Rendered surface.** Picker placement, labels (£ not GBP), detected suffix. Process/UX nits are not money P1s unless they cause the wrong currency to be submitted.

Verdict: READY-TO-MERGE or CHANGES-REQUIRED. P1 merge-blocking / P2 should-fix / P3 nit, each with file:line + one-line fix.
Do not modify files in the author's checkout. Do not push or comment.
