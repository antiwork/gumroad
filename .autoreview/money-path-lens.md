# Domain lens: buyer-currency quote for tipped non-USD listings

This PR removes the cart-level "no tip on non-USD listing" quote gate and instead signs
canonical line components (price/tip/seller_tax/gumroad_tax/shipping) into the quote token,
then applies those components at charge time so listed-currency rounding cannot fail verify!.

Review as a MONEY PATH. Numbered checks:

1. **Display vs charge identity.** Quote-time `charge_canonical_component_cents` and
   charge-time `apply_buyer_currency_quote_canonical_components!` must produce the same
   `price_cents` / `total_transaction_cents` / tax / shipping / tip USD split that
   `verify!` will recompute. A shown-one-price-charged-another is P0.

2. **Double-count / overwrite order.** `prepare_for_charge` already adds shipping into
   `price_cents` and `total_transaction_cents` BEFORE `apply_buyer_currency_quote_canonical_components!`.
   Confirm the apply method fully overwrites (does not add on top of already-added shipping/tax).
   Mutant: drop the overwrite and only add — does any spec redden?

3. **Token is not an attacker-writable amount.** `canonical_components_hint` is
   signature-checked, expiry-checked, seller-scoped, permalink-scoped, listed-currency-scoped.
   Confirm a tampered component hash cannot raise charged amounts. Confirm missing/expired/
   wrong-seller/wrong-permalink/wrong-currency all fall back to the old path (nil hint),
   not a hard fail that bricks checkout AND not a silent accept of unsigned numbers.

4. **Hint is applied only on the intended cohort.** CreateService sets the attr only when
   listed currency != USD AND tip_cents > 0. Confirm USD + tip, non-USD + no tip, and
   missing token still take the previous arithmetic. Confirm a leftover attr on a USD
   purchase cannot rewrite USD amounts.

5. **Rounding / largest-remainder tip split.** The deleted comment said the gate was
   cart-level because largest-remainder tip split can hand a cent to a different line
   between quote and submit. Removing the gate without pinning per-line components to
   the SAME line at charge time reopens the original "total mismatch" failure. Confirm
   permalink-keyed components survive a remapped remainder, and that a line that
   received 0 tip at quote cannot pick up another line's tip at charge.

6. **JPY / single-unit vs KRW/TWD.** Gumroad scales every currency by 100 except JPY
   (`unit_scaling_factor` / `single_unit` in currencies.json). Do not treat ISO
   zero-decimal as Gumroad zero-decimal. Confirm tip conversion uses the same helper
   as price conversion on both quote and charge.

7. **Two-candidate currency fields.** `link.price_currency_type` vs
   `purchase.displayed_price_currency_type`. Specs that set both to EUR cannot kill a
   mutant that reads the wrong one. Demand a case where they diverge.

8. **Tax-excluded-from-price and gumroad_tax.** Apply adds seller tax into `price_cents`
   only when `was_tax_excluded_from_price`, and always adds gumroad tax into
   `total_transaction_cents` only. Confirm this matches pre-existing
   `prepare_for_charge` / fee math for VAT-inclusive vs exclusive listings, including
   when the quote's seller_tax/gumroad_tax are non-zero.

9. **Shipping now quoted + tipped.** Shipping was previously declared safe; tip was not.
   Combined shipping+tip on a non-USD listing is the new product. Confirm shipping
   cents in the signed components are the converted canonical shipping, not listed
   shipping, and that physical products still charge the same shipping as the quote.

10. **Sibling surfaces.** Grep `tip_cents`, `charge_canonical_component_cents`,
    `buyer_currency_quote`, and the deleted non-USD+tip gate. Recurring, gift,
    installment, bundle, combined-charge, and native-paypal/paypal-commerce paths
    that still convert tip independently can reopen the 1-cent verify! failure.
    Incomplete class coverage is a merge blocker if the root cause can be stated
    without naming a surface.

11. **New specs are load-bearing.** Revert `apply_buyer_currency_quote_canonical_components!`
    to a no-op, or drop `canonical_line_components` from the token: which example
    reddens? If none, the headline change is untested. Previous-variant mutant
    (re-add the cart-level tip gate) must redden the new surcharge spec.

12. **Self-fulfilling assertions.** `canonical_components_hint` returning
    `price_cents: 12_50, tip_cents: 1_25` is only useful if those numbers are
    independently derived from the listed price + rate, not copied from the same
    helper the production code used to mint the token.
