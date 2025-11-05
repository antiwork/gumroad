import * as React from "react";

import { CreatorProfile } from "$app/parsers/profile";
import { classNames } from "$app/utils/classNames";

import { NavigationButton } from "$app/components/Button";
import { CartNavigationButton } from "$app/components/Checkout/CartNavigationButton";
import { useCartItemsCount } from "$app/components/Checkout/useCartItemsCount";
import { Icon } from "$app/components/Icons";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { PoweredByFooter } from "$app/components/PoweredByFooter";

import { FollowForm } from "./FollowForm";

type Props = {
  creatorProfile: CreatorProfile;
  hideFollowForm?: boolean;
  children?: React.ReactNode;
};

export const Layout = ({ creatorProfile, hideFollowForm, children }: Props) => {
  const cartItemsCount = useCartItemsCount();
  const loggedInUser = useLoggedInUser();

  return (
    <div className="flex min-h-full flex-col">
      <header className="relative z-20 border-border bg-background text-lg lg:border-b">
        <div className="mx-auto flex max-w-6xl flex-wrap lg:flex-nowrap lg:items-center lg:gap-6 lg:py-6">
          <Section className="relative order-1 grow lg:order-none lg:flex-1">
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
          </Section>
          {!hideFollowForm ? (
            <Section className="order-3 basis-full lg:order-none lg:basis-auto">
              <FollowForm creatorProfile={creatorProfile} />
            </Section>
          ) : null}
          {creatorProfile.twitter_handle || cartItemsCount ? (
            <Section className="order-2 ml-auto lg:order-none lg:ml-0">
              {creatorProfile.twitter_handle ? (
                <NavigationButton outline href={`https://twitter.com/${creatorProfile.twitter_handle}`} target="_blank">
                  <Icon name="twitter" />
                </NavigationButton>
              ) : null}
              <CartNavigationButton />
            </Section>
          ) : null}
        </div>
      </header>
      <main className="flex-1">
        {children}
        <PoweredByFooter className="mx-auto w-full max-w-6xl lg:py-6 lg:text-left" />
      </main>
    </div>
  );
};

const Section = ({ children, className }: { children: React.ReactNode; className?: string }) => (
  <section
    className={classNames("flex items-center gap-3 border-b border-border px-4 py-8 lg:border-none lg:p-0", className)}
  >
    {children}
  </section>
);
