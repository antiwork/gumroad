import { usePage } from "@inertiajs/react";
import * as React from "react";

import { ShareTab as ShareTabContent } from "$app/components/ProductEdit/ShareTab";

import { ProductEditProvider, EditPageProps } from "./_ProductEditProvider";

export default function ShareTab() {
  const props = usePage<EditPageProps>().props;

  return (
    <ProductEditProvider initialProps={props}>
      <ShareTabContent />
    </ProductEditProvider>
  );
}
