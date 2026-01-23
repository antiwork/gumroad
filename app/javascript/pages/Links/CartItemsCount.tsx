import * as React from "react";

import { CartState, newCartState } from "$app/components/Checkout/cartState";

const CartItemsCount = ({ cart }: { cart: CartState | null }) => {
  React.useEffect(() => {
    void document.hasStorageAccess().then((hasAccess) =>
      window.parent.postMessage({
        type: "cart-items-count",
        cartItemsCount: hasAccess ? (cart ?? newCartState()).items.length : "not-available",
      }),
    );
  }, [cart]);

  return null;
};

export default CartItemsCount;
