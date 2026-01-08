import * as React from "react";

import { CreatorProfile } from "$app/parsers/profile";

import { NavigationButton } from "$app/components/Button";
import { CartNavigationButton } from "$app/components/Checkout/CartNavigationButton";
import { useCartItemsCount } from "$app/components/Checkout/useCartItemsCount";
import { Icon } from "$app/components/Icons";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { PoweredByFooter } from "$app/components/PoweredByFooter";
import { useIsAboveBreakpoint } from "$app/components/useIsAboveBreakpoint";

import { FollowForm } from "./FollowForm";

type LayoutProps = {
  creatorProfile: CreatorProfile;
  hideFollowForm?: boolean;
  children?: React.ReactNode;
};

export const Layout = ({ creatorProfile, hideFollowForm, children }: LayoutProps) => {
  const cartItemsCount = useCartItemsCount();
  const loggedInUser = useLoggedInUser();
  const isDesktop = useIsAboveBreakpoint("lg");

  const headerButtons =
    creatorProfile.twitter_handle || cartItemsCount ? (
      <div className="ml-auto flex items-center gap-3">
        {creatorProfile.twitter_handle ? (
          <NavigationButton outline href={`https://twitter.com/${creatorProfile.twitter_handle}`} target="_blank">
            <Icon name="twitter" />
          </NavigationButton>
        ) : null}
        <CartNavigationButton />
      </div>
    ) : null;

  return (
    <div className="flex min-h-full flex-col">
      <header className="z-20 border-border bg-background text-lg lg:border-b lg:px-4 lg:py-6">
        <div className="mx-auto flex max-w-6xl flex-wrap lg:flex-nowrap lg:items-center lg:gap-6">
          <div className="relative flex grow items-center gap-3 border-b border-border px-4 py-8 lg:flex-1 lg:border-0 lg:p-0">
            {(loggedInUser?.isGumroadAdmin || loggedInUser?.isImpersonating) &&
            creatorProfile.external_id !== loggedInUser.id ? (
              <NavigationButton
                href={Routes.admin_impersonate_url({
                  user_identifier: creatorProfile.external_id,
                })}
                className="left-3"
                color="filled"
              >
                Impersonate
              </NavigationButton>
            ) : null}
            <img className="user-avatar" src={creatorProfile.avatar_url} alt="Profile Picture" />
            <a href={Routes.root_path()} className="no-underline">
              {creatorProfile.name}
            </a>
            {!isDesktop ? headerButtons : null}
          </div>
          {!hideFollowForm ? (
            <div className="flex basis-full items-center gap-3 border-b border-border px-4 py-8 lg:basis-auto lg:border-0 lg:p-0">
              <FollowForm creatorProfile={creatorProfile} />
            </div>
          ) : null}
          {isDesktop ? headerButtons : null}
        </div>
      </header>
      <main className="flex-1">
        {children}
        <PoweredByFooter className="mx-auto w-full max-w-6xl lg:py-6 lg:text-left" />
      </main>
    </div>
  );
};
