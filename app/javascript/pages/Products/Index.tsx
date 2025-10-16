import { usePage } from "@inertiajs/react";
import React from "react";

import {
  default as ProductsDashboardPage,
  type ProductsDashboardPageProps,
} from "$app/components/ProductsDashboardPage";

function index() {
  const { react_products_page_props } = usePage<{ react_products_page_props: ProductsDashboardPageProps }>().props;

  return <ProductsDashboardPage {...react_products_page_props} />;
}

export default index;
