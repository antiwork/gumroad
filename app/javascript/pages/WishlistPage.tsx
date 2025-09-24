import { usePage } from "@inertiajs/react";
import React from "react";

import { default as WishlistPage } from "$app/components/server-components/WishlistPage";
import { WishlistProps } from "$app/components/Wishlist";

function WishlistPageIndex() {
  const { wishlist_page_props } = usePage<{ wishlist_page_props: WishlistProps }>().props;

  return <WishlistPage {...wishlist_page_props} />;
}

export default WishlistPageIndex;
