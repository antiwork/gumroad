import * as React from "react";
import { createCast } from "ts-safe-cast";

import { Taxonomy } from "$app/utils/discover";
import { register } from "$app/utils/serverComponentUtil";

import { Layout } from "$app/components/Discover/Layout";
import { Wishlist, WishlistProps } from "$app/components/Wishlist";

const DiscoverWishlistPage: React.FC<Omit<WishlistProps, "isDiscover"> & { taxonomies_for_nav: Taxonomy[] }> = ({
  taxonomies_for_nav,
  ...props
}) => (
  <Layout taxonomiesForNav={taxonomies_for_nav}>
    <Wishlist isDiscover {...props} />
  </Layout>
);

export default register({ component: DiscoverWishlistPage, propParser: createCast() });
