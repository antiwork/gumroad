import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import { Wishlist, WishlistProps } from "$app/components/Wishlist";

const WishlistPage = (props: WishlistProps) => (
  <main>
    <Wishlist {...props} />
  </main>
);

export default register({ component: WishlistPage, propParser: createCast() });
