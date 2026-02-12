import { usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { PoweredByFooter } from "$app/components/PoweredByFooter";
import { Product, useSelectionFromUrl, Props as ProductProps } from "$app/components/Product";
import { useElementDimensions } from "$app/components/useElementDimensions";
import { useRunOnce } from "$app/components/useRunOnce";

function IframeProductShowPage() {
  const props = cast<ProductProps>(usePage().props);

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
}

IframeProductShowPage.loggedInUserLayout = true;
export default IframeProductShowPage;
