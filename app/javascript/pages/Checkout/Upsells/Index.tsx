import { usePage } from "@inertiajs/react";
import React from "react";

import { default as UpsellsPage, UpsellsPageProps } from "$app/components/CheckoutDashboard/UpsellsPage";

function Upsells() {
  const { pages, upsells, products, pagination } = usePage<UpsellsPageProps>().props;

  return <UpsellsPage pages={pages} upsells={upsells} products={products} pagination={pagination} />;
}

export default Upsells;
