import React from "react";
import ProductEditLayout from "$app/layouts/ProductEditLayout";
import { Layout } from "$app/components/ProductEdit/Layout";
import { ProductTab } from "$app/components/ProductEdit/ProductTab";
import { ProductPreview } from "$app/components/ProductEdit/ProductPreview";
import { useImageUpload } from "$app/components/ProductEdit/ProductTab/DescriptionEditor";

function ProductPage() {
  const { isUploading } = useImageUpload();
  const [showRefundPolicyPreview] = React.useState(false);

  return (
    <Layout preview={<ProductPreview showRefundPolicyModal={showRefundPolicyPreview} />} isLoading={isUploading}>
      <ProductTab />
    </Layout>
  );
}

ProductPage.layout = (page: React.ReactNode) => <ProductEditLayout children={page} />;

export default ProductPage;
