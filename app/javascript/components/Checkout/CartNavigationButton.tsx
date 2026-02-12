import * as React from "react";

import { NavigationButton } from "$app/components/Button";
import { useCartItemsCount } from "$app/components/Checkout/useCartItemsCount";
import { useAppDomain } from "$app/components/DomainSettings";
import { Icon } from "$app/components/Icons";

export const CartNavigationButton = ({ className }: { className?: string }) => {
  const appDomain = useAppDomain();
  const cartItemsCount = useCartItemsCount();

  return cartItemsCount ? (
    <NavigationButton className={className} color="filled" href={Routes.checkout_url({ host: appDomain })}>
      <Icon name="cart3-fill" />
      {cartItemsCount === "not-available" ? null : cartItemsCount}
    </NavigationButton>
  ) : null;
};
