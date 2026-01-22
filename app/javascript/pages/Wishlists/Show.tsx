import { usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { Taxonomy } from "$app/utils/discover";

import { Layout as DiscoverLayout } from "$app/components/Discover/Layout";
import { Layout as ProfileLayout } from "$app/components/Profile/Layout";
import { Wishlist, WishlistProps } from "$app/components/Wishlist";

type Props = WishlistProps & {
  layout?: string | null;
  creator_profile?: React.ComponentProps<typeof ProfileLayout>["creatorProfile"];
  taxonomies_for_nav?: Taxonomy[];
};

export default function WishlistShowPage() {
  const { layout, creator_profile, taxonomies_for_nav, ...wishlistProps } = cast<Props>(usePage().props);

  if (layout === "profile" && creator_profile) {
    return (
      <ProfileLayout creatorProfile={creator_profile}>
        <Wishlist layout="profile" {...wishlistProps} user={null} />
      </ProfileLayout>
    );
  }

  if (layout === "discover" && taxonomies_for_nav) {
    return (
      <DiscoverLayout taxonomiesForNav={taxonomies_for_nav} forceDomain>
        <Wishlist layout="discover" {...wishlistProps} />
      </DiscoverLayout>
    );
  }

  return <Wishlist {...wishlistProps} />;
}
WishlistShowPage.loggedInUserLayout = true;
