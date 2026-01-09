import * as React from "react";

import { ProductEditProvider } from "$app/components/ProductEdit/Provider";
import { ShareTab } from "$app/components/ProductEdit/ShareTab";

export default function ProductEditShare() {
  return (
    <ProductEditProvider currentTab="share">
      <ShareTab currentTab="share" />
    </ProductEditProvider>
  );
}
