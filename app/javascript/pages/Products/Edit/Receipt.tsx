import * as React from "react";

import { ProductEditProvider } from "$app/components/ProductEdit/Provider";
import { ReceiptTab } from "$app/components/ProductEdit/ReceiptTab";

export default function ProductEditReceipt() {
  return (
    <ProductEditProvider currentTab="receipt">
      <ReceiptTab currentTab="receipt" />
    </ProductEditProvider>
  );
}
