import { usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { Layout, ProductEditProps } from "$app/components/ProductEdit/Layout";
import { ProductPreview } from "$app/components/ProductEdit/ProductPreview";
import { ProductTab } from "$app/components/ProductEdit/ProductTab";
import { useImageUpload } from "$app/components/ProductEdit/ProductTab/DescriptionEditor";

export default function ProductEditIndex() {
  const props = cast<ProductEditProps>(usePage().props);
  console.log({ props });

  const { isUploading } = useImageUpload();

  const [showRefundPolicyPreview, setShowRefundPolicyPreview] = React.useState(false);

  return (
    <Layout
      currentTab="product"
      preview={<ProductPreview showRefundPolicyModal={showRefundPolicyPreview} />}
      isLoading={isUploading}
      props={props}
    >
      <ProductTab setShowRefundPolicyPreview={setShowRefundPolicyPreview} />
    </Layout>
  );
}
