import { usePage } from "@inertiajs/react";
import React from "react";

import { default as WishlistsFollowingPage, WishlistsFollowingPageProps } from "$app/components/WishlistsFollowingPage";

function WishlistsFollowing() {
  const { wishlists, reviews_page_enabled } = usePage<WishlistsFollowingPageProps>().props;

  return <WishlistsFollowingPage wishlists={wishlists} reviews_page_enabled={reviews_page_enabled} />;
}

export default WishlistsFollowing;
