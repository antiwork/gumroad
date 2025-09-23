import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import { PoweredByFooter } from "$app/components/PoweredByFooter";
import { Product, useSelectionFromUrl, Props as ProductProps } from "$app/components/Product";
import { useElementDimensions } from "$app/components/useElementDimensions";
import { useRunOnce } from "$app/components/useRunOnce";

const IframePage = (props: ProductProps) => {
  useRunOnce(() => window.parent.postMessage({ type: "loaded" }, "*"));
  useRunOnce(() => window.parent.postMessage({ type: "translations", translations: { close: "Close" } }, "*"));
  const mainRef = React.useRef<HTMLDivElement>(null);
  const dimensions = useElementDimensions(mainRef);
  React.useEffect(() => {
    if (dimensions) window.parent.postMessage({ type: "height", height: dimensions.height }, "*");
  }, [dimensions]);
  const [selection, setSelection] = useSelectionFromUrl(props.product);

  return (
    <div>
      <div ref={mainRef}>
        <section>
          <Product
            {...props}
            discountCode={props.discount_code}
            selection={selection}
            setSelection={setSelection}
            ctaLabel="Add to cart"
          />
        </section>
        <PoweredByFooter className="p-0" />
      </div>
    </div>
  );
};

export default register({ component: IframePage, propParser: createCast() });
