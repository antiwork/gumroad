import * as React from "react";

import { CartItemsCount, cartItemsCountSrc, loadCartItemsCount } from "$app/utils/cart";

import { useDomains } from "$app/components/DomainSettings";
import { useRunOnce } from "$app/components/useRunOnce";

export const useCartItemsCount = () => {
  const { rootDomain } = useDomains();
  const [cartItemsCount, setCartItemsCount] = React.useState<CartItemsCount | null>(null);

  useRunOnce(() => loadCartItemsCount(cartItemsCountSrc(rootDomain), setCartItemsCount));

  return cartItemsCount;
};
