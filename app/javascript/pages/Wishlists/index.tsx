import { usePage } from "@inertiajs/react";
import React from "react";

import { default as WishlistsPage, WishlistsPageProps } from "$app/components/server-components/WishlistsPage";

function Wishlists() {
  const { wishlists_props } = usePage<{ wishlists_props: WishlistsPageProps }>().props;

  return <WishlistsPage {...wishlists_props} />;
}

export default Wishlists;
