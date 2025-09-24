import { usePage } from "@inertiajs/react";
import React from "react";

import { Taxonomy } from "$app/utils/discover";

import { default as DiscoverWishlistPage } from "$app/components/server-components/Discover/WishlistPage";
import { WishlistProps } from "$app/components/Wishlist";

function DiscoverWishlistPageIndex() {
  const { wishlist_page_props } = usePage<{
    wishlist_page_props: Omit<WishlistProps, "isDiscover"> & { taxonomies_for_nav: Taxonomy[] };
  }>().props;

  return <DiscoverWishlistPage {...wishlist_page_props} />;
}

export default DiscoverWishlistPageIndex;
