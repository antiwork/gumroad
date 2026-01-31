import * as React from "react";

import { Button } from "$app/components/ui/Button";
import { useCartItemsCount } from "$app/components/Checkout/useCartItemsCount";
import { useAppDomain } from "$app/components/DomainSettings";
import { Icon } from "$app/components/Icons";

export const CartNavigationButton = ({ className }: { className?: string }) => {
  const appDomain = useAppDomain();
  const cartItemsCount = useCartItemsCount();

  return cartItemsCount ? (
    <Button asChild className={className} color="filled">
      <a href={Routes.checkout_index_url({ host: appDomain })}>
        <Icon name="cart3-fill" />
        {cartItemsCount === "not-available" ? null : cartItemsCount}
      </a>
    </Button>
  ) : null;
};
