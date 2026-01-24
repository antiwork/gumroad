import * as React from "react";
import { usePage } from "@inertiajs/react";
import { CartState, newCartState } from "$app/components/Checkout/cartState";

type Props = {
  cart: CartState | null;
};

export default function CartItemsCountPage() {
  const { cart } = usePage<Props>().props;

  React.useEffect(() => {
    document.hasStorageAccess().then((hasAccess) =>
      window.parent.postMessage({
        type: "cart-items-count",
        cartItemsCount: hasAccess ? (cart ?? newCartState()).items.length : "not-available",
      }),
    );
  }, [cart]);

  return null;
}

CartItemsCountPage.disableLayout = true;
