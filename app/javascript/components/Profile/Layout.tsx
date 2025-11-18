import * as React from "react";

import { CreatorProfile } from "$app/parsers/profile";
import { classNames } from "$app/utils/classNames";

import { NavigationButton } from "$app/components/Button";
import { CartNavigationButton } from "$app/components/Checkout/CartNavigationButton";
import { useCartItemsCount } from "$app/components/Checkout/useCartItemsCount";
import { Icon } from "$app/components/Icons";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { PoweredByFooter } from "$app/components/PoweredByFooter";
import { useIsAboveBreakpoint } from "$app/components/useIsAboveBreakpoint";

import { FollowForm } from "./FollowForm";

type Props = {
  creatorProfile: CreatorProfile;
  hideFollowForm?: boolean;
  children?: React.ReactNode;
};

export const Layout = ({ creatorProfile, hideFollowForm, children }: Props) => {
  const cartItemsCount = useCartItemsCount();
  const loggedInUser = useLoggedInUser();
  const isDesktop = useIsAboveBreakpoint("lg");

  const sectionClassName = "flex items-center gap-3 border-b border-border px-4 py-8 lg:border-none lg:p-0";

  if (isDesktop) {
    return (
      <div className="flex min-h-full flex-col">
        <header className="relative z-20 border-b border-border bg-background text-lg">
          <div className="mx-auto flex max-w-6xl flex-nowrap items-center gap-6 py-6">
            <section className={classNames(sectionClassName, "relative flex-1 grow")}>
              {(loggedInUser?.isGumroadAdmin || loggedInUser?.isImpersonating) &&
              creatorProfile.external_id !== loggedInUser.id ? (
                <NavigationButton
                  href={Routes.admin_impersonate_url({ user_identifier: creatorProfile.external_id })}
                  className="absolute left-3"
                  color="filled"
                >
                  Impersonate
                </NavigationButton>
              ) : null}
              <img className="user-avatar" src={creatorProfile.avatar_url} alt="Profile Picture" />
              <a href={Routes.root_path()} className="no-underline">
                {creatorProfile.name}
              </a>
            </section>
            {!hideFollowForm ? (
              <section className={sectionClassName}>
                <FollowForm creatorProfile={creatorProfile} />
              </section>
            ) : null}
            {creatorProfile.twitter_handle || cartItemsCount ? (
              <section className={sectionClassName}>
                {creatorProfile.twitter_handle ? (
                  <NavigationButton
                    outline
                    href={`https://twitter.com/${creatorProfile.twitter_handle}`}
                    target="_blank"
                  >
                    <Icon name="twitter" />
                  </NavigationButton>
                ) : null}
                <CartNavigationButton />
              </section>
            ) : null}
          </div>
        </header>
        <main className="flex-1">
          {children}
          <PoweredByFooter className="mx-auto w-full max-w-6xl lg:py-6 lg:text-left" />
        </main>
      </div>
    );
  }

  return (
    <div className="flex min-h-full flex-col">
      <header className="relative z-20 bg-background text-lg">
        <div className="mx-auto flex max-w-6xl flex-wrap">
          <section className={classNames(sectionClassName, "relative grow")}>
            {(loggedInUser?.isGumroadAdmin || loggedInUser?.isImpersonating) &&
            creatorProfile.external_id !== loggedInUser.id ? (
              <NavigationButton
                href={Routes.admin_impersonate_url({ user_identifier: creatorProfile.external_id })}
                className="absolute left-3"
                color="filled"
              >
                Impersonate
              </NavigationButton>
            ) : null}
            <img className="user-avatar" src={creatorProfile.avatar_url} alt="Profile Picture" />
            <a href={Routes.root_path()} className="no-underline">
              {creatorProfile.name}
            </a>
          </section>
          {creatorProfile.twitter_handle || cartItemsCount ? (
            <section className={classNames(sectionClassName, "ml-auto")}>
              {creatorProfile.twitter_handle ? (
                <NavigationButton outline href={`https://twitter.com/${creatorProfile.twitter_handle}`} target="_blank">
                  <Icon name="twitter" />
                </NavigationButton>
              ) : null}
              <CartNavigationButton />
            </section>
          ) : null}
          {!hideFollowForm ? (
            <section className={classNames(sectionClassName, "basis-full")}>
              <FollowForm creatorProfile={creatorProfile} />
            </section>
          ) : null}
        </div>
      </header>
      <main className="flex-1">
        {children}
        <PoweredByFooter className="mx-auto w-full max-w-6xl" />
      </main>
    </div>
  );
};
