import { usePage } from "@inertiajs/react";
import React from "react";

import {
  default as ProductsDashboardPage,
  type ProductsDashboardPageProps,
} from "$app/components/ProductsDashboardPage";

function index() {
  const props = usePage<ProductsDashboardPageProps>().props;

  return <ProductsDashboardPage {...props} />;
}

export default index;
