import * as React from "react";

import { BundleProduct } from "$app/components/BundleEdit/state";
import { Thumbnail } from "$app/components/Product/Thumbnail";
import { useIsAboveBreakpoint } from "$app/components/useIsAboveBreakpoint";

export const BundleProductSelector = ({
  bundleProduct,
  selected,
  onToggle,
}: {
  bundleProduct: BundleProduct;
  selected?: boolean;
  onToggle: () => void;
}) => {
  const isDesktop = useIsAboveBreakpoint("sm");

  return (
    <label role="listitem">
      <section style={{ gridTemplateColumns: isDesktop ? "5rem 1fr auto" : undefined }}>
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
        <section style={{ justifyContent: "center" }}>
          <input type="checkbox" checked={!!selected} onChange={onToggle} />
        </section>
      </section>
    </label>
  );
};
