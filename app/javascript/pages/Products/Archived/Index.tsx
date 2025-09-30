import { usePage } from "@inertiajs/react";
import React from "react";

import { default as ArchivedProductsPage, ArchivedProductsPageProps } from "$app/components/ArchivedProductsPage";

function Archived() {
  const { memberships, memberships_pagination, products, products_pagination, can_create_product } =
    usePage<ArchivedProductsPageProps>().props;

  return (
    <ArchivedProductsPage
      memberships={memberships}
      memberships_pagination={memberships_pagination}
      products={products}
      products_pagination={products_pagination}
      can_create_product={can_create_product}
    />
  );
}

export default Archived;
