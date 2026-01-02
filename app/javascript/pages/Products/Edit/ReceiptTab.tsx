import { usePage } from "@inertiajs/react";
import * as React from "react";

import { ReceiptTab as ReceiptTabContent } from "$app/components/ProductEdit/ReceiptTab";

import { ProductEditProvider, EditPageProps } from "./_ProductEditProvider";

export default function ReceiptTab() {
  const props = usePage<EditPageProps>().props;

  return (
    <ProductEditProvider initialProps={props}>
      <ReceiptTabContent />
    </ProductEditProvider>
  );
}
