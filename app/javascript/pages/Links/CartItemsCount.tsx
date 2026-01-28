import { CartState, newCartState } from "$app/components/Checkout/cartState";

const CartItemsCount = ({ cart }: { cart: CartState | null }) => {
  void document.hasStorageAccess().then((hasAccess) =>
    window.parent.postMessage({
      type: "cart-items-count",
      cartItemsCount: hasAccess ? (cart ?? newCartState()).items.length : "not-available",
    }),
  );

  return null;
};

export default CartItemsCount;
