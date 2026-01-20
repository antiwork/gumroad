import { usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { Layout, ProductEditProps } from "$app/components/ProductEdit/Layout";
import { ReceiptPreview } from "$app/components/ProductEdit/ReceiptPreview";
import { ReceiptTabContent } from "$app/components/ProductEdit/ReceiptTab";

export default function ReceiptTab() {
  const props = cast<ProductEditProps>(usePage().props);

  return (
    <Layout
      currentTab="receipt"
      preview={<ReceiptPreview />}
      previewScaleFactor={1}
      showBorder={false}
      showNavigationButton={false}
      props={props}
    >
      <ReceiptTabContent />
    </Layout>
  );
}
