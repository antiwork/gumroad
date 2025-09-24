import * as React from "react";

import { Taxonomy } from "$app/utils/discover";

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

export default DiscoverWishlistPage;
