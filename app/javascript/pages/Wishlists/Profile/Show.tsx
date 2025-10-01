import { usePage } from "@inertiajs/react";
import React from "react";

import { default as ProfileWishlistPage, ProfileWishlistPageProps } from "$app/components/Profile/WishlistPage";

function ProfileWishlistPageIndex() {
  const props = usePage<ProfileWishlistPageProps>().props;

  return <ProfileWishlistPage {...props} />;
}

export default ProfileWishlistPageIndex;
