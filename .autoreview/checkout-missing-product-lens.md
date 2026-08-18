# Domain lens: checkout cart update rejecting items that omit product.id

This PR changes `CheckoutController#update` so a cart item missing `product` / `product.id`
is rejected BEFORE the transaction, instead of 500ing on `item[:product][:id]`.

This is a cart/checkout item-mutation money path. Numbered checks:

1. **Id-namespace consistency.** The new guard reads `item[:product][:id]` — the same key
   `Link.find_by_external_id!` already used. Confirm both official checkout and this guard
   share the `external_id` namespace. A mismatch would make the guard a no-op or reject
   valid official payloads.

2. **Reject vs skip.** Skipping invalid items inside `filter_map` would persist the remaining
   items as "the whole cart" and soft-delete every existing cart product. Confirm the guard
   returns before `cart.lock!` / the deletion step, and that a mixed valid+flattened payload
   does not delete existing products. A spec that only sends ALL-invalid items cannot see
   `any?` vs `all?`.

3. **Degradation for ordinary products.** Official checkout always sends `{ product: { id } }`.
   Confirm the happy path is unchanged (no extra redirect, no false reject on blank-string
   vs missing key vs `product: {}`).

4. **Server-side re-validation of the trimmed payload.** The client removing/omitting an item
   can break a later guard. Confirm `accepted_offer` attribution is not silently orphaned by
   this reject (the whole update is aborted, so existing rows stay).

5. **Alert / copy reachability.** The buyer-facing string must be a real checkout alert the
   page renders. A 500-to-redirect change: confirm JSON/mobile clients that relied on the
   500, `status: :see_other` for POST→GET, and that the existing scalar-`cart` / max-items
   redirects stay reachable.

6. **Does this cover the whole bug class?** Enumerate other ways `item[:product][:id]` can be
   unusable (whitespace-only id, non-string, unknown external id → `find_by_external_id!`
   RecordNotFound). Classify each as handled / pre-existing / in-scope miss.

7. **Specs load-bearing.** Mutate `any?` → `all?` and demand the mixed-cart example reddens.
   Mutate the guard away and demand the omit-`product.id` example raises NoMethodError.
   A spec that derives expected cart state from the same payload the controller just saved
   is tautological.

8. **No money movement on the reject path.** Confirm this action only persists cart rows;
   it must not charge, refund, or reprice. The blast radius is cart contents + checkout 500s.
