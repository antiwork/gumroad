import { usePage } from "@inertiajs/react";
import React from "react";

import {
  default as ProfileWishlistPage,
  ProfileWishlistPageProps,
} from "$app/components/server-components/Profile/WishlistPage";

function ProfileWishlistPageIndex() {
  const { wishlist_page_props } = usePage<{ wishlist_page_props: ProfileWishlistPageProps }>().props;

  return <ProfileWishlistPage {...wishlist_page_props} />;
}

export default ProfileWishlistPageIndex;
