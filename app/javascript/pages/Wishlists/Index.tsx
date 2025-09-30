import { usePage } from "@inertiajs/react";
import React from "react";

import { default as WishlistsPage, WishlistsPageProps } from "$app/components/WishlistsPage";

function Wishlists() {
  const { wishlists, reviews_page_enabled, following_wishlists_enabled } = usePage<WishlistsPageProps>().props;

  return (
    <WishlistsPage
      wishlists={wishlists}
      reviews_page_enabled={reviews_page_enabled}
      following_wishlists_enabled={following_wishlists_enabled}
    />
  );
}

export default Wishlists;
