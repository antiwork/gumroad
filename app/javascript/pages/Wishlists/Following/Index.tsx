import { usePage } from "@inertiajs/react";
import React from "react";
import { cast } from "ts-safe-cast";

import WishlistsFollowingPage from "$app/components/Wishlists/WishlistsFollowingPage";

type Props = React.ComponentProps<typeof WishlistsFollowingPage>;

export default function WishlistsFollowingIndex() {
  const props = cast<Props>(usePage().props);

  return <WishlistsFollowingPage {...props} />;
}
