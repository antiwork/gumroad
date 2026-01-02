import { usePage } from "@inertiajs/react";
import * as React from "react";

import { ContentTab as ContentTabContent } from "$app/components/ProductEdit/ContentTab";

import { ProductEditProvider, EditPageProps } from "./_ProductEditProvider";

export default function ContentTab() {
  const props = usePage<EditPageProps>().props;

  return (
    <ProductEditProvider initialProps={props}>
      <ContentTabContent />
    </ProductEditProvider>
  );
}
