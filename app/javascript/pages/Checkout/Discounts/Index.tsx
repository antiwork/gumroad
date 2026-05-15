import { usePage } from "@inertiajs/react";
import React from "react";
import typia from "typia";

import { default as DiscountsPage, DiscountsPageProps } from "$app/components/CheckoutDashboard/DiscountsPage";

function Discounts() {
  const {
    offer_codes,
    pages,
    products,
    pagination,
    show_black_friday_banner,
    black_friday_code,
    black_friday_code_name,
  } = typia.assert<DiscountsPageProps>(usePage().props);

  return (
    <DiscountsPage
      offer_codes={offer_codes}
      pages={pages}
      products={products}
      pagination={pagination}
      show_black_friday_banner={show_black_friday_banner}
      black_friday_code={black_friday_code}
      black_friday_code_name={black_friday_code_name}
    />
  );
}

export default Discounts;
