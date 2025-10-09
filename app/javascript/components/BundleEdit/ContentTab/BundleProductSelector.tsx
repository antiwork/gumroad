import * as React from "react";

import { BundleProduct } from "$app/components/BundleEdit/state";
import { Thumbnail } from "$app/components/Product/Thumbnail";

export const BundleProductSelector = ({
  bundleProduct,
  selected,
  onToggle,
}: {
  bundleProduct: BundleProduct;
  selected?: boolean;
  onToggle: () => void;
}) => {

  return (
    <label role="listitem">
      <section className="override lg:!grid-cols-[5rem_1fr_auto]">
        <figure>
          <Thumbnail url={bundleProduct.thumbnail_url} nativeType={bundleProduct.native_type} />
        </figure>
        <section>
          <h4>{bundleProduct.name}</h4>
          {bundleProduct.variants ? (
            <footer>
              {bundleProduct.variants.list.length} {bundleProduct.variants.list.length === 1 ? "version" : "versions"}{" "}
              available
            </footer>
          ) : null}
        </section>
        <section className="justify-center">
          <input type="checkbox" checked={!!selected} onChange={onToggle} />
        </section>
      </section>
    </label>
  );
};
