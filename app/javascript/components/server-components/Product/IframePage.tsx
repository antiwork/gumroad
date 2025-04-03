import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import { Product, useSelectionFromUrl, Props as ProductProps } from "$app/components/Product";
import { useElementDimensions } from "$app/components/useElementDimensions";
import { useRunOnce } from "$app/components/useRunOnce";

const IframePage = (props: ProductProps) => {
  useRunOnce(() => window.parent.postMessage({ type: "loaded" }, "*"));
  useRunOnce(() => window.parent.postMessage({ type: "translations", translations: { close: "Close" } }, "*"));
  const mainRef = React.useRef<HTMLElement>(null);
  const dimensions = useElementDimensions(mainRef);
  React.useEffect(() => {
    if (dimensions) window.parent.postMessage({ type: "height", height: dimensions.height }, "*");
  }, [dimensions]);
  const [selection, setSelection] = useSelectionFromUrl(props.product);

  return (
    <div>
      <main ref={mainRef}>
        <section>
          <Product
            {...props}
            discountCode={props.discount_code}
            selection={selection}
            setSelection={setSelection}
            ctaLabel="Add to cart"
          />
        </section>
        <footer style={{ borderTop: "none", padding: 0 }}>
          Powered by <span className="logo-full" />
        </footer>
      </main>
    </div>
  );
};

export default register({ component: IframePage, propParser: createCast() });
