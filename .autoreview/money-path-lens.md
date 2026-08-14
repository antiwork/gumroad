Round-7 panel of gumroad#7229 head 38c3ce1fa89f6181db5f1764d9187a5575c964c9
("Fix checkout currency picker test import order.").

This is a MONEY PATH. Displayed currency vs charged currency must be identical.
Prior panel at 1edf4098449bc05581e63b4365c39f39d04d558e (r6) is STALE by the file-list gate:
git diff 1edf40984..38c3ce1fa --name-only -- app lib config db is NON-EMPTY
(app/javascript/components/Checkout/index.test.tsx — import order only).
Executable production app/lib/config/db is UNCHANGED vs r6. Grade THIS head anyway.
Do not rubber-stamp because the delta is a test import reorder. Re-verify every r6 finding against THIS tree.

Do not modify any files in the author's working tree. Do not push or comment.
Restore any mutated file before finishing. Demand mutation proof, not coverage reasoning.

R6 FINDINGS (checklist — mark RESOLVED / STILL-OPEN / REGRESSED with file:line on THIS tree):
1. P1 CurrencyPicker ignores willSaveCard: picker advertises EUR/other presentment while save-card forces canonical USD charge (index.tsx CurrencyPicker hide condition vs buyerCurrencyDisplay.ts).
2. P1 buyerCurrencyPreference.test.ts never sets URL and cookie together; a precedence swap would not redden.
3. P1 Known-but-refused requested currency is still stub-only (customer_surcharge_controller_spec stubs BuyerCurrencyQuote.create → nil). Cart-wide create() refusals never prune other advertised currencies.
4. P1 Weakened have_no_text("Total €") lets line-item EUR amounts pass while the charge is USD (buyer_currency_save_card_spec + buyer_local_currency_display_spec).
5. P1 Picker remains visible when buyer_currency_quote is nil and falls back to detected currency, advertising a presentment the charge will not honor.

Also re-grade earlier still-open class items if they regressed:
6. Wallet / non-card: picker-selected currency displayed but Apple Pay/Google Pay/PayPal charges canonical USD.
7. unguarded decodeURIComponent on gumroad_buyer_currency cookie.
8. available_buyer_currencies advertised when all_lines_quotable is false.

Currency / money-path lenses:
- shown amount vs charged amount identity on every payment method
- KRW/TWD are NOT zero-decimal in Gumroad (only JPY via single_unit)
- fail-closed on unsettleable currencies (picker must not advertise a currency the charge path will not honor)
- cookie/URL preference must not crash checkout
- two-candidate sources (URL vs cookie vs IP) need a competing-values test
- a compound guard needs one mutation PER half
- confirm isWalletPaymentElementType covers every Apple Pay / Google Pay / Payment Request type string
- save-card / willSaveCard is not a chargeable presentment
- self-fulfilling assertions that derive expected currency from the same helper as production
- a non-USD picker value must only be selected when a matching quote exists
