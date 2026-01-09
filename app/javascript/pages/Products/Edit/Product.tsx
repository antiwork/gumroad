import * as React from "react";

import { ProductEditProvider } from "$app/components/ProductEdit/Provider";
import { ProductTab } from "$app/components/ProductEdit/ProductTab";

export default function ProductEditProduct() {
  return (
    <ProductEditProvider currentTab="product">
      <ProductTab currentTab="product" />
    </ProductEditProvider>
  );
}
