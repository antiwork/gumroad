import React from "react";
import ProductEditLayout from "$app/layouts/ProductEditLayout";
import { Layout } from "$app/components/ProductEdit/Layout";
import { ProductTab } from "$app/components/ProductEdit/ProductTab";
import { ProductPreview } from "$app/components/ProductEdit/ProductPreview";
import { useImageUpload } from "$app/components/ProductEdit/ProductTab/DescriptionEditor";
import { useProductEditContext } from "$app/components/ProductEdit/state";

function ProductPage() {
  const { isUploading } = useImageUpload();
  const [showRefundPolicyPreview] = React.useState(false);
  const { uniquePermalink, registerSaveConfig } = useProductEditContext();

  React.useEffect(() => {
    registerSaveConfig({ updateUrl: Routes.product_product_path(uniquePermalink) });
    return () => registerSaveConfig(null);
  }, [uniquePermalink, registerSaveConfig]);

  return (
    <Layout preview={<ProductPreview showRefundPolicyModal={showRefundPolicyPreview} />} isLoading={isUploading}>
      <ProductTab />
    </Layout>
  );
}

ProductPage.layout = (page: React.ReactNode) => <ProductEditLayout children={page} />;

export default ProductPage;
