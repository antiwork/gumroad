Round-9 panel of gumroad#7229 head 7b0d5f10b260cc44f62c7eb102f8d27113c13756
("Recapture checkout currency stills at 5023ed6332."). This is a MONEY PATH.

Prior panel at a78ba680d7428f956f531e18873dc0e33f7190d2 is STALE by the file-list gate:
git diff a78ba680d7..7b0d5f10b --name-only -- app lib config db is NON-EMPTY
(customer_surcharge_controller.rb, Checkout/index.tsx, buyerCurrencyDisplay.ts,
Show.tsx, currency.ts, plus new tests). Re-verify every prior finding against THIS tree.
The tip commit itself is QA-media only; the reviewable delta is b7a958617..5023ed633
(rmarescu review-fix commits + KRW controller-detection follow-up).

Do not modify any files in the author's working tree. Do not push or comment.
Restore any mutated file before finishing. Demand mutation proof, not coverage reasoning.

R8 FINDINGS (checklist — mark RESOLVED / STILL-OPEN / REGRESSED with file:line on THIS tree):
1. P1 CurrencyPicker ignores willSaveCard: picker advertises EUR/other presentment while save-card forces canonical USD charge. Later commit dee30c24f claims "Hide picker while saving a card" — verify the hide condition actually includes willSaveCard AND that displayed totals match the USD charge.
2. P1 buyerCurrencyPreference.test.ts never sets URL and cookie together; a precedence swap would not redden.
3. P1 Known-but-refused requested currency is still stub-only. Cart-wide create() refusals never prune other advertised currencies. Later commit b7a958617 claims "Gate checkout currency choices" — verify advertised list vs BuyerCurrencyQuote.create gates (seller_enabled?, MAX_QUOTED_CHARGES, charge_minor_units_compatible?).
4. P1 Weakened have_no_text("Total €") lets line-item EUR amounts pass while the charge is USD.
5. P1 Picker remains visible / selected when buyer_currency_quote is nil and falls back to detected currency. Later commit 008df8a72 claims "Synchronize unavailable currency choice" — verify selected value cannot be a non-USD code without a matching quote.
6. Wallet / non-card: picker-selected currency displayed but Apple Pay/Google Pay/PayPal charges canonical USD.
7. unguarded decodeURIComponent on gumroad_buyer_currency cookie.
8. available_buyer_currencies advertised when all_lines_quotable is false.

NEW delta since a78ba680 (must also review):
9. Hide picker for listed-currency carts (60be87645). Confirm listed-currency / Payment Element lanes never show a picker that can switch away from the product's listed currency, and that display still matches charge.
10. Respect zero-decimal currencies (c9ebda4ae). Gumroad scaling: only JPY is single_unit. KRW and TWD are ISO zero-decimal but Gumroad scales them by 100. A comment/doc/test teaching the ISO rule is a money-safety finding.
11. Keep KRW quote test on controller detection (5023ed633). Confirm the spec still drives the REAL controller detection path (not a tautological in-spec recompute).
12. Pass payment element to quote token (523627a3d). Confirm wallet / save-card / card presentment all mint the token the charge path will actually submit.
13. Drop an unquotable detected currency (291e3f00f). Confirm detected-but-unsettleable codes fail closed to a chargeable currency, not an advertised presentment with a nil quote.
14. Scope canonical price assertions (f63a4f1e7). Confirm they are not self-fulfilling (do not derive expected from the same helper production uses).
15. Shown amount vs charged amount identity on every payment method (card, save-card, wallet, PayPal, listed-currency).
16. Two independent booleans (willSaveCard × wallet × quote-present × listed-currency) are a PRODUCT; ask for the truth table. if a / elsif b / else ships 3 of 4.
17. A non-USD picker value must only be selected when a matching quote exists.
18. Compound guards need one mutation PER half. Preference-chain order untested until one example has BOTH candidates.

Currency / money-path lenses:
- shown amount vs charged amount identity
- KRW/TWD are NOT zero-decimal in Gumroad (only JPY via single_unit)
- fail-closed on unsettleable currencies
- cookie/URL preference must not crash checkout
- two-candidate sources (URL vs cookie vs IP) need a competing-values test
- confirm isWalletPaymentElementType covers every Apple Pay / Google Pay / Payment Request type string
- save-card / willSaveCard is not a chargeable presentment
- self-fulfilling assertions
