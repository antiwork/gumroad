import React from "react";
import ProductEditLayout from "$app/layouts/ProductEditLayout";
import { Layout } from "$app/components/ProductEdit/Layout";
import { ReceiptTab } from "$app/components/ProductEdit/ReceiptTab";
import { ReceiptPreview } from "$app/components/ProductEdit/ReceiptPreview";

function ReceiptPage() {
  return (
    <Layout preview={<ReceiptPreview />} previewScaleFactor={1} showBorder={false} showNavigationButton={false}>
      <ReceiptTab />
    </Layout>
  );
}

ReceiptPage.layout = (page: React.ReactNode) => <ProductEditLayout children={page} />;

export default ReceiptPage;
