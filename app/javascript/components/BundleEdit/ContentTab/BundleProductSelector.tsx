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
  const { locale } = useUserAgentInfo();

  const formatCreatedAt = (isoDate: string): string => {
    const date = new Date(isoDate);
    return date.toLocaleDateString(locale, {
      year: "numeric",
      month: "short",
      day: "numeric",
    });
  };

  const cleanUrl = (url: string): string => url.replace(/^https?:\/\//u, "");

  return (
    <CartItem>
      <CartItemMedia className="sm:w-24">
        <Thumbnail url={bundleProduct.thumbnail_url} nativeType={bundleProduct.native_type} className="size-full" />
      </CartItemMedia>
      <CartItemMain>
        <CartItemTitle>{bundleProduct.name}</CartItemTitle>
        <a href={bundleProduct.url} target="_blank" rel="noopener noreferrer nofollow" className="text-sm underline">
          {cleanUrl(bundleProduct.url)}
        </a>
        <CartItemFooter>
          <span>
            {formatCreatedAt(bundleProduct.created_at)}
            {bundleProduct.variants ? (
              <>
                {" · "}
                {bundleProduct.variants.list.length} {bundleProduct.variants.list.length === 1 ? "version" : "versions"}{" "}
                available
              </>
            ) : null}
          </span>
        </CartItemFooter>
      </CartItemMain>
      <CartItemEnd className="justify-center">
        <input type="checkbox" aria-label={bundleProduct.name} checked={!!selected} onChange={onToggle} />
      </CartItemEnd>
    </CartItem>
  );
};
