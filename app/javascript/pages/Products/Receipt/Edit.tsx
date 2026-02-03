import React from "react";
import ProductEditLayout from "$app/layouts/ProductEditLayout";
import { Layout } from "$app/components/ProductEdit/Layout";
import { ReceiptTab } from "$app/components/ProductEdit/ReceiptTab";
import { ReceiptPreview } from "$app/components/ProductEdit/ReceiptPreview";
import { useProductEditContext } from "$app/components/ProductEdit/state";

function ReceiptPage() {
  const { uniquePermalink, registerSaveConfig } = useProductEditContext();

  React.useEffect(() => {
    registerSaveConfig({ updateUrl: Routes.product_receipt_path(uniquePermalink) });
    return () => registerSaveConfig(null);
  }, [uniquePermalink, registerSaveConfig]);

  return (
    <Layout preview={<ReceiptPreview />} previewScaleFactor={1} showBorder={false} showNavigationButton={false}>
      <ReceiptTab />
    </Layout>
  );
}

ReceiptPage.layout = (page: React.ReactNode) => <ProductEditLayout children={page} />;

export default ReceiptPage;
