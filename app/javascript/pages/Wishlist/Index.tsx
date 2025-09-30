import { usePage } from "@inertiajs/react";
import React from "react";

import { WishlistProps } from "$app/components/Wishlist";
import { default as WishlistPage } from "$app/components/WishlistPage";

function WishlistPageIndex() {
  const props = usePage<WishlistProps>().props;

  return <WishlistPage {...props} />;
}

export default WishlistPageIndex;
