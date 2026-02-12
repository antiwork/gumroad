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
import { useUserAgentInfo } from "$app/components/UserAgent";

export const BundleProductSelector = ({
  bundleProduct,
  selected,
  onToggle,
}: {
  bundleProduct: BundleProduct;
  selected?: boolean;
  onToggle: () => void;
}) => {
  const userAgentInfo = useUserAgentInfo();

  return (
    <CartItem>
      <CartItemMedia className="sm:w-24">
        <Thumbnail url={bundleProduct.thumbnail_url} nativeType={bundleProduct.native_type} className="size-full" />
      </CartItemMedia>
      <CartItemMain>
        <div>
          <CartItemTitle>{bundleProduct.name}</CartItemTitle>
          <a href={bundleProduct.url} target="_blank" rel="noopener noreferrer nofollow">
            {bundleProduct.url}
          </a>
        </div>
        <CartItemFooter>
          <ul className="inline">
            <li>
              {new Date(bundleProduct.creation_date).toLocaleDateString(userAgentInfo.locale, {
                month: "numeric",
                day: "numeric",
                year: "numeric",
              })}
            </li>
            {bundleProduct.variants ? (
              <li>
                {bundleProduct.variants.list.length} {bundleProduct.variants.list.length === 1 ? "version" : "versions"}{" "}
                available
              </li>
            ) : null}
          </ul>
        </CartItemFooter>
      </CartItemMain>
      <CartItemEnd className="justify-center">
        <input type="checkbox" aria-label={bundleProduct.name} checked={!!selected} onChange={onToggle} />
      </CartItemEnd>
    </CartItem>
  );
};
