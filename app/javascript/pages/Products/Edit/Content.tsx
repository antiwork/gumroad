import * as React from "react";

import { ProductEditProvider } from "$app/components/ProductEdit/Provider";
import { ContentTab } from "$app/components/ProductEdit/ContentTab";

export default function ProductEditContent() {
  return (
    <ProductEditProvider currentTab="content">
      <ContentTab currentTab="content" />
    </ProductEditProvider>
  );
}
