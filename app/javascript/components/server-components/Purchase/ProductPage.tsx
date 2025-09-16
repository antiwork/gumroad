import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import { PoweredByFooter } from "$app/components/PoweredByFooter";
import { Product, useSelectionFromUrl, Props as ProductProps } from "$app/components/Product";

const PurchaseProductPage = (props: ProductProps) => {
  const [selection, setSelection] = useSelectionFromUrl(props.product);

  return (
    <div>
      <div>
        <section>
          <Product {...props} selection={selection} setSelection={setSelection} />
        </section>
        <PoweredByFooter className="p-0" />
      </div>
    </div>
  );
};

export default register({ component: PurchaseProductPage, propParser: createCast() });
