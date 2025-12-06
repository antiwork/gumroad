import { usePage } from "@inertiajs/react";
import React from "react";
import { cast } from "ts-safe-cast";

import WishlistsPage from "$app/components/WishlistsPage";

type Props = {
  wishlists: {
    id: string;
    name: string;
    url: string;
    product_count: number;
    discover_opted_out: boolean;
  }[];
  reviews_page_enabled: boolean;
  following_wishlists_enabled: boolean;
};

export default function WishlistsIndex() {
  const props = cast<Props>(usePage().props);
  return <WishlistsPage {...props} />;
}
