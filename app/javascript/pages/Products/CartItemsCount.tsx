import { usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

type Props = {
  cart_items_count: number;
};

const CartItemsCount = () => {
  const { cart_items_count } = cast<Props>(usePage().props);

  React.useEffect(() => {
    void document.hasStorageAccess().then((hasAccess) =>
      window.parent.postMessage(
        {
          type: "cart-items-count",
          cartItemsCount: hasAccess ? cart_items_count : "not-available",
        },
        "*",
      ),
    );
  }, [cart_items_count]);

  return null;
};

CartItemsCount.disableLayout = true;
export default CartItemsCount;
