import { usePage } from "@inertiajs/react";
import React from "react";

import { Taxonomy } from "$app/utils/discover";

import { default as DiscoverWishlistPage } from "$app/components/server-components/Discover/WishlistPage";
import { WishlistProps } from "$app/components/Wishlist";

function DiscoverWishlistPageIndex() {
  const props = usePage<Omit<WishlistProps, "isDiscover"> & { taxonomies_for_nav: Taxonomy[] }>().props;

  return <DiscoverWishlistPage {...props} />;
}

export default DiscoverWishlistPageIndex;
