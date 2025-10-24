import * as React from "react";

import { BundleProduct } from "$app/components/BundleEdit/state";
import {
  CartListItem,
  CartItemEnd,
  CartItemMain,
  CartItemMedia,
  CartItemTitle,
  CartItemFooter,
} from "$app/components/CartList";
import { Thumbnail } from "$app/components/Product/Thumbnail";

export const BundleProductSelector = ({
  bundleProduct,
  selected,
  onToggle,
}: {
  bundleProduct: BundleProduct;
  selected?: boolean;
  onToggle: () => void;
}) => (
  <CartListItem className="sm:*:grid-cols-[5rem_1fr_auto]">
    <CartItemMedia>
      <Thumbnail url={bundleProduct.thumbnail_url} nativeType={bundleProduct.native_type} />
    </CartItemMedia>
    <CartItemMain>
      <CartItemTitle>{bundleProduct.name}</CartItemTitle>
      {bundleProduct.variants ? (
        <CartItemFooter>
          {bundleProduct.variants.list.length} {bundleProduct.variants.list.length === 1 ? "version" : "versions"}{" "}
          available
        </CartItemFooter>
      ) : null}
    </CartItemMain>
    <CartItemEnd className="justify-center">
      <input type="checkbox" checked={!!selected} onChange={onToggle} />
    </CartItemEnd>
  </CartListItem>
);
