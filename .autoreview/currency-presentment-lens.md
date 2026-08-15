# Domain lens: buyer presentment currency (footer selector + checkout picker)

This branch adds a footer currency selector that writes `gumroad_buyer_currency` and
threads `preferred_currency` into product/discover/profile presentment. Checkout already
has a picker. Review as a MONEY path: shown price vs charged price.

Numbered checks (treat misses as P1 unless proven unreachable):

1. **Shown-vs-charged identity.** Every surface that renders a converted price must
   resolve the same currency the charge path will use. Product/discover/profile after a
   footer pick vs `/checkout` quote vs actual charge. A host-only cookie that cannot
   cross `seller.gumroad.com` / custom domain → `gumroad.com/checkout` is a shown-vs-charged
   mismatch.

2. **Cookie Domain / custom-domain carry.** Does `writeBuyerCurrencyPreference` set
   `Domain=.<root>` on `*.gumroad.com`? How does a custom-domain pick reach checkout?
   Read both the writer and every reader (TS + Ruby).

3. **URL-param vs cookie precedence and validation.** If `?currency=` is read before
   `isKnownCurrencyCode`, an invalid param must not mask a valid cookie. A valid param
   that is rendered but never persisted will drop at checkout. Check BOTH
   `buyerCurrencyPreference.ts` and the Ruby helper for the same shape.

4. **Key type on `request.params`.** `ActionDispatch::Request#params` is a plain Hash
   with String keys. A Symbol lookup (`[:currency]`) silently no-ops. Confirm the live
   path and that the new spec would actually fail if the key is wrong.

5. **Picker must not assert a currency the quote did not honour.** If
   `buyer_currency_quote` is null, the select must not show a detected/preferred currency
   as selected while totals stay USD. `available_buyer_currencies` must apply the same
   gates as quote creation (seller flag, minor-units, MAX_QUOTED_CHARGES, item shape,
   StripeFxQuote failure).

6. **Settleability gates unchanged for an explicit pick.** An explicit currency still
   only displays if the charge path can honour it. No new bypass of
   `buyer_currency_settleable?` / seller enablement.

7. **Gumroad unit rule, not ISO.** `unit_scaling_factor` / `single_unit` is JPY-only;
   KRW and TWD scale by 100. Labels, surcharge, and quote must not treat them as
   zero-decimal.

8. **Two-candidate sources.** Do not let specs set product currency and purchase
   snapshot to the same value and claim they pin the right one.

9. **Rendered surfaces.** Footer layout (Gumroad left, Currency right) on product,
   discover, invoices/profile. Copy/route reality of any new labels. Two independent
   booleans (detected vs preferred vs quote-failed) — ask for the truth table.
