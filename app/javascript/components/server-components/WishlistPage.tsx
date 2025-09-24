import * as React from "react";

import { Wishlist, WishlistProps } from "$app/components/Wishlist";

const WishlistPage = (props: WishlistProps) => (
  <div>
    <Wishlist {...props} />
  </div>
);

export default WishlistPage;
