import { usePage } from "@inertiajs/react";
import React from "react";
import { cast } from "ts-safe-cast";

import WishlistsPage from "$app/components/Wishlists/WishlistsPage";

type Props = React.ComponentProps<typeof WishlistsPage>;

export default function WishlistsIndex() {
  const props = cast<Props>(usePage().props);

  return <WishlistsPage {...props} />;
}
