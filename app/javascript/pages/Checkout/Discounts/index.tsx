import { usePage } from "@inertiajs/react";
import React from "react";

import {
  default as DiscountsPage,
  DiscountsPageProps,
} from "$app/components/server-components/CheckoutDashboard/DiscountsPage";

function Discounts() {
  const { discounts_page_props } = usePage<{ discounts_page_props: DiscountsPageProps }>().props;

  return <DiscountsPage {...discounts_page_props} />;
}

export default Discounts;
