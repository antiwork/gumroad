import { usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { CartState, newCartState } from "$app/components/Checkout/cartState";

type Props = {
  cart: CartState | null;
};

const CartItemsCount = () => {
  const { cart } = cast<Props>(usePage().props);

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

CartItemsCount.disableLayout = true;
export default CartItemsCount;
