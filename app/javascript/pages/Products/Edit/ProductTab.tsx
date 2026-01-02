import { usePage } from "@inertiajs/react";
import * as React from "react";

import { ProductTab as ProductTabContent } from "$app/components/ProductEdit/ProductTab";

import { ProductEditProvider, EditPageProps } from "./_ProductEditProvider";

export default function ProductTab() {
  const props = usePage<EditPageProps>().props;

  return (
    <ProductEditProvider initialProps={props}>
      <ProductTabContent />
    </ProductEditProvider>
  );
}
