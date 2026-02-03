import React from "react";
import ProductEditLayout from "$app/layouts/ProductEditLayout";
import { Layout } from "$app/components/ProductEdit/Layout";
import { ShareTab } from "$app/components/ProductEdit/ShareTab";
import { ProductPreview } from "$app/components/ProductEdit/ProductPreview";
import { useProductEditContext } from "$app/components/ProductEdit/state";

function SharePage() {
  const { uniquePermalink, registerSaveConfig } = useProductEditContext();

  React.useEffect(() => {
    registerSaveConfig({ updateUrl: Routes.product_share_path(uniquePermalink) });
    return () => registerSaveConfig(null);
  }, [uniquePermalink, registerSaveConfig]);

  return (
    <Layout preview={<ProductPreview />}>
      <ShareTab />
    </Layout>
  );
}

SharePage.layout = (page: React.ReactNode) => <ProductEditLayout children={page} />;

export default SharePage;
