import cx from "classnames";
import * as React from "react";

import { CreatorProfile } from "$app/parsers/profile";

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

  const sectionClassName =
    "col-[unset] row-[unset] flex items-center gap-3 border-b border-border px-4 py-8 lg:border-0 lg:p-0";

  return (
    <div className={cx("grid min-h-full grid-rows-[auto_1fr]", className)}>
      <header className="relative z-20 grid grid-cols-1 bg-background text-[1.15rem] leading-[1.4] lg:grid-flow-col lg:items-center lg:gap-8 lg:border-b lg:border-border lg:px-profile-desktop-padding lg:py-6">
        <section className={sectionClassName}>
          {(loggedInUser?.isGumroadAdmin || loggedInUser?.isImpersonating) &&
          creatorProfile.external_id !== loggedInUser.id ? (
            <NavigationButton
              style={{ position: "absolute", left: "var(--spacer-3)" }}
              color="filled"
              href={Routes.admin_impersonate_url({ user_identifier: creatorProfile.external_id })}
            >
              Impersonate
            </NavigationButton>
          ) : null}
          <img className="user-avatar" src={creatorProfile.avatar_url} alt="Profile Picture" />
          <a href={Routes.root_path()} style={{ textDecoration: "none" }}>
            {creatorProfile.name}
          </a>
        </section>
        {!hideFollowForm ? (
          <section className={cx(sectionClassName, "col-span-2")}>
            <FollowForm creatorProfile={creatorProfile} />
          </section>
        ) : null}
        {creatorProfile.twitter_handle || cartItemsCount ? (
          <section className={cx(sectionClassName, "col-2 row-1")}>
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
        className={cx(
          "custom-sections row-[unset] *:lg:px-profile-desktop-padding",
          loggedInUser?.id === creatorProfile.external_id && "has-user",
        )}
      >
        {children}
        <PoweredByFooter />
      </main>
    </div>
  );
};
