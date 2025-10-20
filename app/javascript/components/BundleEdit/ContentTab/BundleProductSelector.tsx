import * as React from "react";

import { BundleProduct } from "$app/components/BundleEdit/state";
import { CartListItem } from "$app/components/CartList";
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
  <CartListItem
    media={<Thumbnail url={bundleProduct.thumbnail_url} nativeType={bundleProduct.native_type} />}
    title={<h4>{bundleProduct.name}</h4>}
    body={
      bundleProduct.variants ? (
        <>
          {bundleProduct.variants.list.length} {bundleProduct.variants.list.length === 1 ? "version" : "versions"}{" "}
          available
        </>
      ) : null
    }
    end={<input type="checkbox" checked={!!selected} onChange={onToggle} />}
    endClassName="justify-center"
    className="sm:*:grid-cols-[5rem_1fr_auto]"
  />
);
