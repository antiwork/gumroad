# Domain lens: checkout cart update reject-missing-product.id

This PR is money-path: `CheckoutController#update` is the cart-save that checkout payment
reads. A wrong filter here can empty a live cart or 500 the payment page.

Previous heads `4117466e0f58a53c121f4fba986ef4bef036b03b` and `10342a8fd3` reviewed clean
on panel. THIS head `f92e2e2268f4eede9f6ef1a8b96476c46f5925c8` changes the buyer-facing
alert from the generic "Sorry, something went wrong. Please try again." to
"A product in your cart is missing. Refresh the page and try again." Grade the NEW
copy + the still-present reject-before-transaction guard.

Numbered checks:

1. **Reject-before-transaction, not skip-inside-filter_map.** Skipping a missing-id item
   inside `filter_map` would make `updated_cart_products` omit it, then
   `cart.alive_cart_products.where.not(id: updated_cart_products.map(&:id)).find_each
   { mark_deleted }` would soft-delete every existing cart product. Confirm the guard
   still returns BEFORE `ActiveRecord::Base.transaction` and does not persist a partial
   mixed cart.

2. **Id-namespace consistency.** Official checkout sends `{ product: { id } }` as
   `external_id`. Confirm the guard does not compare two different id namespaces, and
   that a present-but-unresolvable id still falls through to `Link.find_by_external_id!`
   (not silently treated as missing).

3. **Degradation for the matching case.** Official checkout items with `product.id` must
   be unchanged. The new branch must not fire on a well-formed payload.

4. **Server-side re-validation.** Rejecting the whole PATCH must leave existing cart
   products, email, discount codes, and accepted_offer rows untouched. Mixed
   valid+flattened items must not persist the valid item.

5. **Copy / client-router.** The new alert is buyer-facing. Confirm it is accurate
   (the product is missing from the *payload*, not necessarily deleted from the
   catalog). Confirm the redirect is still `checkout_path` and does not notify Sentry
   (`ErrorNotifier`) for expected bad input.

6. **Does `item[:product]` being a scalar/string still 500?** Strong params + a
   flattened client might send `product` as a string. `item[:product][:id]` would
   raise if the blank? guard is only on the hash. Probe that shape.

7. **Quantity-0 removal signal vs missing product.id.** A legitimate removal
   (`quantity: 0` with a product id) must still work. A quantity-0 item that ALSO
   omits product.id is invalid input — confirm it is rejected, not treated as removal.

8. **Specs load-bearing.** Mutating `items.any?` → `items.all?` must redden the mixed
   cart example. Changing the alert string must redden the flash assertion. A whole-file
   revert of the guard must redden both new examples.
