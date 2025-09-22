import { usePage } from "@inertiajs/react";
import React from "react";

import {
  default as ArchivedProductsPage,
  ArchivedProductsPageProps,
} from "$app/components/server-components/ArchivedProductsPage";

function Archived() {
  const { archived_products_page_props } = usePage<{ archived_products_page_props: ArchivedProductsPageProps }>().props;

  return <ArchivedProductsPage {...archived_products_page_props} />;
}

export default Archived;
