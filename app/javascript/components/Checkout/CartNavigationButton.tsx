import { Cart } from "@boxicons/react";
import * as React from "react";

import { useCartItemsCount } from "$app/components/Checkout/useCartItemsCount";
import { useAppDomain } from "$app/components/DomainSettings";
import { NavigationButton } from "$app/components/ui/NavigationButton";

export const CartNavigationButton = ({ className }: { className?: string }) => {
  const appDomain = useAppDomain();
  const cartItemsCount = useCartItemsCount();

  return cartItemsCount ? (
    <NavigationButton className={className} color="filled" href={Routes.checkout_url({ host: appDomain })}>
      <Cart pack="filled" className="size-5" />
      {cartItemsCount === "not-available" ? null : cartItemsCount}
    </NavigationButton>
  ) : null;
};
