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
  className?: string;
  creatorProfile: CreatorProfile;
  hideFollowForm?: boolean;
  children?: React.ReactNode;
};

export const Layout = ({ className, creatorProfile, hideFollowForm, children }: Props) => {
  const cartItemsCount = useCartItemsCount();
  const loggedInUser = useLoggedInUser();
  const isReaderMode = className?.includes("reader");

  return (
    <div className={classNames("grid min-h-full grid-rows-[auto_1fr]", className)}>
  <header className="relative z-20 grid grid-cols-1 bg-background text-[1.15rem] leading-[1.4] lg:grid-flow-col lg:items-center lg:gap-8 lg:border-b lg:border-border lg:px-[max(calc((100%-71.25rem)/2),4rem)] lg:py-6 [.squished_&]:lg:px-4">
        <section className="flex items-center gap-3 border-b border-border p-4 pt-8 pb-8 lg:border-none lg:p-0">
          {(loggedInUser?.isGumroadAdmin || loggedInUser?.isImpersonating) &&
          creatorProfile.external_id !== loggedInUser.id ? (
            <NavigationButton
              className="absolute left-3"
              color="filled"
              href={Routes.admin_impersonate_url({ user_identifier: creatorProfile.external_id })}
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
          <section className="flex items-center gap-3 border-b border-border p-4 pt-8 pb-8 lg:border-none lg:p-0">
            <FollowForm creatorProfile={creatorProfile} />
          </section>
        ) : null}
        {creatorProfile.twitter_handle || cartItemsCount ? (
          <section className="flex items-center gap-3 border-b border-border p-4 pt-8 pb-8 lg:col-start-2 lg:row-auto lg:row-start-1 lg:border-none lg:p-0">
            {creatorProfile.twitter_handle ? (
              <NavigationButton outline href={`https://twitter.com/${creatorProfile.twitter_handle}`} target="_blank">
                <Icon name="twitter" />
              </NavigationButton>
            ) : null}
            <CartNavigationButton />
          </section>
        ) : null}
      </header>
      <main
        className={classNames(
          "[&>*]:lg:px-[max(calc((100%-71.25rem)/2),4rem)] [.squished_&]:[&>*]:lg:px-4",
          isReaderMode && "[&>article]:text-[1.15rem] [&>article]:leading-[1.4]",
          isReaderMode && "lg:[&>article]:pr-[max(calc(100%-50rem-max(calc((100%-71.25rem)/2),4rem)),4rem)]",
          isReaderMode && "lg:[&>.comments]:pr-[max(calc(100%-50rem-max(calc((100%-71.25rem)/2),4rem)),4rem)]",
        )}
      >
        {children}
        <PoweredByFooter className="lg:py-6 lg:text-left" />
      </main>
    </div>
  );
};
