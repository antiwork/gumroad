import { usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { ContentTabContent } from "$app/components/ProductEdit/ContentTab";
import ConfirmDiscardVariantModal from "$app/components/ProductEdit/ContentTab/ConfirmDiscardVariantModal";
import HeaderActions from "$app/components/ProductEdit/ContentTab/HeaderActions";
import { Layout, ProductEditProps } from "$app/components/ProductEdit/Layout";

declare global {
  interface Window {
    ___dropbox_files_picked: DropboxFile[] | null;
  }
}

//TODO inline this once all the crazy providers are gone
export default function ContentTab() {
  const props = cast<ProductEditProps>(usePage().props);
  const [selectedVariantId, setSelectedVariantId] = React.useState(props.product.variants[0]?.id ?? null);
  const [confirmingDiscardVariantContent, setConfirmingDiscardVariantContent] = React.useState(false);

  return (
    <Layout
      props={props}
      currentTab="content"
      headerActions={
        <HeaderActions
          selectedVariantId={selectedVariantId}
          setSelectedVariantId={setSelectedVariantId}
          setConfirmingDiscardVariantContent={setConfirmingDiscardVariantContent}
        />
      }
    >
      <ContentTabContent selectedVariantId={selectedVariantId} />
      <ConfirmDiscardVariantModal
        selectedVariantId={selectedVariantId}
        confirmingDiscardVariantContent={confirmingDiscardVariantContent}
        setConfirmingDiscardVariantContent={setConfirmingDiscardVariantContent}
      />
    </Layout>
  );
}
