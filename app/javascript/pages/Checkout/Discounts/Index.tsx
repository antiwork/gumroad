import { usePage } from "@inertiajs/react";
import React from "react";

import { default as DiscountsPage, DiscountsPageProps } from "$app/components/CheckoutDashboard/DiscountsPage";

function Discounts() {
  const { offer_codes, pages, products, pagination } = usePage<DiscountsPageProps>().props;

  return <DiscountsPage offer_codes={offer_codes} pages={pages} products={products} pagination={pagination} />;
}

export default Discounts;
