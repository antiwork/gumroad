import { usePage } from "@inertiajs/react";
import React from "react";

import {
  default as UpsellsPage,
  UpsellsPageProps,
} from "$app/components/server-components/CheckoutDashboard/UpsellsPage";

function Upsells() {
  const { upsells_page_props } = usePage<{ upsells_page_props: UpsellsPageProps }>().props;

  return <UpsellsPage {...upsells_page_props} />;
}

export default Upsells;
