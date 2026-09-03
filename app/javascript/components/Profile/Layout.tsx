import { Pencil, Star, TwitterX, Youtube } from "@boxicons/react";
import * as React from "react";

import { CreatorProfile } from "$app/parsers/profile";

import { NavigationButton } from "$app/components/Button";
import { CartNavigationButton } from "$app/components/Checkout/CartNavigationButton";
import { useCartItemsCount } from "$app/components/Checkout/useCartItemsCount";
import { useAppDomain } from "$app/components/DomainSettings";
import { PoweredByFooter } from "$app/components/PoweredByFooter";
import { TopCreatorBadge } from "$app/components/Product/AuthorByline";
import { FollowForm } from "$app/components/Profile/FollowForm";
import { Avatar } from "$app/components/ui/Avatar";
import { useIsAboveBreakpoint } from "$app/components/useIsAboveBreakpoint";
import { WithTooltip } from "$app/components/WithTooltip";

type LayoutProps = {
  creatorProfile: CreatorProfile;
  hideFollowForm?: boolean;
  // Off by default: this layout also runs the product editor's preview and the profile settings
  // preview, where a buyer currency control belongs to nobody and a reload discards unsaved edits.
  currencySelector?: boolean | undefined;
  shownCurrency?: string | null | undefined;
  children?: React.ReactNode;
};

export const Layout = ({ creatorProfile, hideFollowForm, currencySelector, shownCurrency, children }: LayoutProps) => {
  const cartItemsCount = useCartItemsCount();
  const appDomain = useAppDomain();
  const isDesktop = useIsAboveBreakpoint("lg");
  const hideSubscribeForm = hideFollowForm || Boolean(creatorProfile.hide_follow_form);
  const youtubeChannelId = creatorProfile.youtube_channel_id;

  const headerButtons =
    creatorProfile.can_edit || creatorProfile.twitter_handle || youtubeChannelId || cartItemsCount ? (
      <div className="flex shrink-0 items-center gap-3 lg:ml-auto">
        {creatorProfile.can_edit ? (
          <NavigationButton color="filled" className="whitespace-nowrap" href={Routes.profile_url({ host: appDomain })}>
            <Pencil className="size-5" />
            Edit profile
          </NavigationButton>
        ) : null}
        {creatorProfile.twitter_handle ? (
          <NavigationButton outline href={`https://twitter.com/${creatorProfile.twitter_handle}`} target="_blank">
            <TwitterX pack="brands" className="size-5" />
          </NavigationButton>
        ) : null}
        {youtubeChannelId ? (
          <NavigationButton
            outline
            href={`https://www.youtube.com/channel/${encodeURIComponent(youtubeChannelId)}`}
            target="_blank"
            aria-label="YouTube"
          >
            <Youtube pack="brands" className="size-5" />
          </NavigationButton>
        ) : null}
        <CartNavigationButton />
      </div>
    ) : null;

  return (
    <div className="flex min-h-screen flex-col">
      <header className="z-20 border-border bg-background text-lg lg:border-b lg:px-4 lg:py-6">
        <div className="mx-auto flex max-w-6xl flex-wrap lg:flex-nowrap lg:items-center lg:gap-6">
          <div className="relative flex min-w-0 grow flex-wrap items-center gap-3 border-b border-border p-4 lg:flex-1 lg:flex-nowrap lg:border-0 lg:p-0">
            {creatorProfile.avatar_url ? <Avatar src={creatorProfile.avatar_url} alt="Profile Picture" /> : null}
            <a href={Routes.root_path()} className="flex max-w-full min-w-0 items-center gap-2 no-underline">
              <span className="truncate">{creatorProfile.name}</span>
              {creatorProfile.is_verified ? (
                <WithTooltip tip="Top creator" position="bottom" className="shrink-0">
                  <TopCreatorBadge />
                </WithTooltip>
              ) : null}
            </a>
            {creatorProfile.reputation ? (
              <div className="flex min-w-0 flex-wrap items-center gap-1 text-sm text-muted" aria-label="Creator rating">
                <Star pack="filled" className="size-4" />
                {`${creatorProfile.reputation.average} from ${creatorProfile.reputation.count} verified ${creatorProfile.reputation.count === 1 ? "review" : "reviews"} across ${creatorProfile.reputation.products_count} products`}
              </div>
            ) : null}
          </div>
          {!hideSubscribeForm ? (
            <div className="flex basis-full items-center gap-3 border-b border-border p-4 lg:basis-auto lg:border-0 lg:p-0">
              <FollowForm creatorProfile={creatorProfile} />
            </div>
          ) : null}
          {!isDesktop && headerButtons ? <div className="flex basis-full p-4 pt-0">{headerButtons}</div> : null}
          {isDesktop ? headerButtons : null}
        </div>
      </header>
      <main className="flex flex-1 flex-col">
        {children}
        <PoweredByFooter
          className="mx-auto w-full max-w-6xl"
          currencySelector={currencySelector}
          shownCurrency={shownCurrency}
        />
      </main>
    </div>
  );
};
