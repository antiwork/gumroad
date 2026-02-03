import React from "react";
import ProductEditLayout from "$app/layouts/ProductEditLayout";
import { Layout } from "$app/components/ProductEdit/Layout";
import { ContentTab, ContentTabHeaderActions } from "$app/components/ProductEdit/ContentTab";
import { useProductEditContext } from "$app/components/ProductEdit/state";

function ContentPage() {
  const [selectedVariantId, setSelectedVariantId] = React.useState<string | null>(null);
  const { uniquePermalink, registerSaveConfig } = useProductEditContext();

  React.useEffect(() => {
    registerSaveConfig({
      updateUrl: Routes.product_content_path(uniquePermalink),
      isContentTab: true,
    });
    return () => registerSaveConfig(null);
  }, [uniquePermalink, registerSaveConfig]);

  return (
    <Layout
      headerActions={
        <ContentTabHeaderActions
          selectedVariantId={selectedVariantId}
          setSelectedVariantId={setSelectedVariantId}
        />
      }
    >
      <ContentTab selectedVariantId={selectedVariantId} />
    </Layout>
  );
}

ContentPage.layout = (page: React.ReactNode) => <ProductEditLayout children={page} />;

export default ContentPage;
