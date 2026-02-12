import * as React from "react";

import { BundleProduct } from "$app/components/BundleEdit/types";
import {
  CartItem,
  CartItemEnd,
  CartItemMain,
  CartItemMedia,
  CartItemTitle,
  CartItemFooter,
} from "$app/components/CartItemList";
import { Thumbnail } from "$app/components/Product/Thumbnail";

const formatCreatedAt = (iso: string) => {
  const date = new Date(iso);
  return date.toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" });
};

export const BundleProductSelector = ({
  bundleProduct,
  selected,
  onToggle,
  showDetails = false,
}: {
  bundleProduct: BundleProduct;
  selected?: boolean;
  onToggle: () => void;
  showDetails?: boolean;
}) => (
  <CartItem>
    <CartItemMedia className="sm:w-24">
      <Thumbnail url={bundleProduct.thumbnail_url} nativeType={bundleProduct.native_type} className="size-full" />
    </CartItemMedia>
    <CartItemMain>
      <CartItemTitle>{bundleProduct.name}</CartItemTitle>
      {showDetails && bundleProduct.url ? (
        <a href={bundleProduct.url} target="_blank" rel="noopener noreferrer" className="text-sm underline">
          {bundleProduct.url.replace(/^https?:\/\//u, "")}
        </a>
      ) : null}
      <CartItemFooter>
        {showDetails && bundleProduct.created_at ? (
          <span>
            {formatCreatedAt(bundleProduct.created_at)}
            {bundleProduct.variants ? (
              <>
                {" \u00b7 "}
                {bundleProduct.variants.list.length} {bundleProduct.variants.list.length === 1 ? "version" : "versions"}{" "}
                available
              </>
            ) : null}
          </span>
        ) : bundleProduct.variants ? (
          <span>
            {bundleProduct.variants.list.length} {bundleProduct.variants.list.length === 1 ? "version" : "versions"}{" "}
            available
          </span>
        ) : null}
      </CartItemFooter>
    </CartItemMain>
    <CartItemEnd className="justify-center">
      <input type="checkbox" aria-label={bundleProduct.name} checked={!!selected} onChange={onToggle} />
    </CartItemEnd>
  </CartItem>
);
