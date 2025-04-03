import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import { CartState, newCartState } from "$app/components/Checkout/cartState";

const CartItemsCountPage = ({ cart }: { cart: CartState | null }) =>
  void document.hasStorageAccess().then((hasAccess) =>
    window.parent.postMessage({
      type: "cart-items-count",
      cartItemsCount: hasAccess ? (cart ?? newCartState()).items.length : "not-available",
    }),
  );

export default register({ component: CartItemsCountPage, propParser: createCast() });
