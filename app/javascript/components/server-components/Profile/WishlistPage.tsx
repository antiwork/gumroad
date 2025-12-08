import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import { Layout as ProfileLayout } from "$app/components/Profile/Layout";
import { Wishlist, WishlistProps } from "$app/components/Wishlist";

type Props = WishlistProps & {
  creator_profile: React.ComponentProps<typeof ProfileLayout>["creatorProfile"];
};

const ProfileWishlistPage = (props: Props) => (
  <ProfileLayout creatorProfile={props.creator_profile}>
    <Wishlist layout="profile" {...props} user={null} />
  </ProfileLayout>
);

export default register({ component: ProfileWishlistPage, propParser: createCast() });
