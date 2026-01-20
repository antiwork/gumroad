import { usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { Layout, ProductEditProps } from "$app/components/ProductEdit/Layout";
import { ProductPreview } from "$app/components/ProductEdit/ProductPreview";
import { ShareTabContent } from "$app/components/ProductEdit/ShareTab";

export default function ShareTab() {
  const props = cast<ProductEditProps>(usePage().props);

  return (
    <Layout currentTab="share" preview={<ProductPreview />} props={props}>
      <ShareTabContent />
    </Layout>
  );
}
