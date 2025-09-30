import * as React from "react";

import { Layout as ProfileLayout } from "$app/components/Profile/Layout";
import { Wishlist, WishlistProps } from "$app/components/Wishlist";

export type ProfileWishlistPageProps = WishlistProps & {
  creator_profile: React.ComponentProps<typeof ProfileLayout>["creatorProfile"];
};

const ProfileWishlistPage = (props: ProfileWishlistPageProps) => (
  <ProfileLayout creatorProfile={props.creator_profile}>
    <Wishlist {...props} user={null} />
  </ProfileLayout>
);

export default ProfileWishlistPage;
