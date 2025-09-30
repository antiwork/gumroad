import { usePage } from "@inertiajs/react";
import React from "react";

import { default as ProductsDashboardPage, ProductsDashboardPageProps } from "$app/components/ProductsDashboardPage";

function index() {
  const {
    memberships,
    memberships_pagination,
    products,
    products_pagination,
    archived_products_count,
    can_create_product,
  } = usePage<ProductsDashboardPageProps>().props;

  return (
    <ProductsDashboardPage
      memberships={memberships}
      memberships_pagination={memberships_pagination}
      products={products}
      products_pagination={products_pagination}
      archived_products_count={archived_products_count}
      can_create_product={can_create_product}
    />
  );
}

export default index;
