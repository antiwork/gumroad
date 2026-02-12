import * as React from "react";

import { NavigationButton } from "$app/components/Button";
import { useCartItemsCount } from "$app/components/Checkout/useCartItemsCount";
import { useAppDomain } from "$app/components/DomainSettings";
import { Cart } from "@boxicons/react";
export const CartNavigationButton = ({ className }: { className?: string }) => {
  const appDomain = useAppDomain();
  const cartItemsCount = useCartItemsCount();

  return cartItemsCount ? (
    <NavigationButton className={className} color="filled" href={Routes.checkout_index_url({ host: appDomain })}>
      <Cart pack="filled" />
      {cartItemsCount === "not-available" ? null : cartItemsCount}
    </NavigationButton>
  ) : null;
};
