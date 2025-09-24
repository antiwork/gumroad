import { usePage } from "@inertiajs/react";
import React from "react";

import {
  default as WishlistsFollowingPage,
  WishlistsFollowingPageProps,
} from "$app/components/server-components/WishlistsFollowingPage";

function WishlistsFollowing() {
  const { wishlists_following_props } = usePage<{ wishlists_following_props: WishlistsFollowingPageProps }>().props;

  return <WishlistsFollowingPage {...wishlists_following_props} />;
}

export default WishlistsFollowing;
