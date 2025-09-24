import { usePage } from "@inertiajs/react";
import React from "react";

import { default as CollabsPage, CollabsPageProps } from "$app/components/server-components/CollabsPage";

function Collabs() {
  const { collab_products_page_props } = usePage<{ collab_products_page_props: CollabsPageProps }>().props;

  return <CollabsPage {...collab_products_page_props} />;
}

export default Collabs;
