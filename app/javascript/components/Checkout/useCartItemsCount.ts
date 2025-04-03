import * as React from "react";

import { CartItemsCount, loadCartItemsCount } from "$app/utils/cart";

import { useRunOnce } from "$app/components/useRunOnce";

export const useCartItemsCount = () => {
  const [cartItemsCount, setCartItemsCount] = React.useState<CartItemsCount | null>(null);

  useRunOnce(() => loadCartItemsCount(Routes.cart_items_count_url(), setCartItemsCount));

  return cartItemsCount;
};
