import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import { Product, useSelectionFromUrl, Props as ProductProps } from "$app/components/Product";

const PurchaseProductPage = (props: ProductProps) => {
  const [selection, setSelection] = useSelectionFromUrl(props.product);

  return (
    <div>
      <main>
        <section>
          <Product {...props} selection={selection} setSelection={setSelection} />
        </section>
        <footer style={{ borderTop: "none", padding: 0 }}>
          Powered by <span className="logo-full" />
        </footer>
      </main>
    </div>
  );
};

export default register({ component: PurchaseProductPage, propParser: createCast() });
