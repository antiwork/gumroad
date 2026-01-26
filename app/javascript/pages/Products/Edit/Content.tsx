import React from "react";
import ProductEditLayout from "$app/layouts/ProductEditLayout";
import { Layout } from "$app/components/ProductEdit/Layout";
import { ContentTab, ContentTabHeaderActions } from "$app/components/ProductEdit/ContentTab";

function ContentPage() {
  const [selectedVariantId, setSelectedVariantId] = React.useState<string | null>(null);

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
