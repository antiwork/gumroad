import { BookmarkHeart } from "@boxicons/react";
import * as React from "react";

import { NavigationButton } from "$app/components/Button";
import { CartNavigationButton } from "$app/components/Checkout/CartNavigationButton";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { useDomains } from "$app/components/DomainSettings";
import { Logo } from "$app/components/Logo";
import { Avatar } from "$app/components/ui/Avatar";

import dollarBurst from "$assets/images/dollar-store/dollar-burst.png";
import storeItalic from "$assets/images/dollar-store/store-italic.png";

const UserActionButtons = () => {
  const currentSeller = useCurrentSeller();

  if (currentSeller) {
    return (
      <>
        <NavigationButton href={Routes.library_url()} className="flex-1 lg:flex-none">
          <BookmarkHeart pack="filled" className="size-5" /> Library
        </NavigationButton>
        {currentSeller.has_published_products ? null : (
          <NavigationButton href={Routes.products_url()} color="primary" className="flex-1 lg:flex-none">
            Start selling
          </NavigationButton>
        )}
      </>
    );
  }

  return (
    <>
      <NavigationButton href={Routes.login_url()} className="flex-1 lg:flex-none">
        Log in
      </NavigationButton>
      <NavigationButton href={Routes.signup_url()} color="primary" className="flex-1 lg:flex-none">
        Start selling
      </NavigationButton>
    </>
  );
};

export const DollarStoreHeader = () => {
  const { discoverDomain, appDomain } = useDomains();
  const currentSeller = useCurrentSeller();

  return (
    <header className="sticky top-0 z-30 bg-white px-4 py-8 lg:ps-16 lg:pe-16">
      <div className="grid w-full grid-cols-[1fr_auto_1fr] items-center gap-4">
        <a href={Routes.discover_url({ host: discoverDomain })} aria-label="Gumroad" className="shrink-0 text-black">
          <Logo className="h-auto w-[245px]" />
        </a>

        <div className="flex items-center gap-2">
          <img src={dollarBurst} alt="$1" className="h-20 w-auto lg:h-24" />
          <img src={storeItalic} alt="store" className="h-7 w-auto lg:h-9" />
        </div>

        <div className="flex shrink-0 items-center justify-end space-x-4">
          <UserActionButtons />
          <CartNavigationButton className="link-button shrink-0" />
          {currentSeller ? (
            <a href={Routes.dashboard_url({ host: appDomain })} aria-label="Dashboard" className="shrink-0">
              <Avatar src={currentSeller.avatarUrl} />
            </a>
          ) : null}
        </div>
      </div>
    </header>
  );
};
