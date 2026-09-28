import * as React from "react";

import { CartItemsCount, cartItemsCountSrc, loadCartItemsCount } from "$app/utils/cart";

import { useRunOnce } from "$app/components/useRunOnce";

export const useCartItemsCount = () => {
  const [cartItemsCount, setCartItemsCount] = React.useState<CartItemsCount | null>(null);

  useRunOnce(() => loadCartItemsCount(cartItemsCountSrc(), setCartItemsCount));

  return cartItemsCount;
};
