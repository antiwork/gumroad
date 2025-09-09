import { usePage } from "@inertiajs/react";
import React from "react";

import { default as BalancePage, BalancePageProps } from "$app/components/server-components/BalancePage";

function index() {
  const { payout_presenter } = usePage<{ payout_presenter: BalancePageProps }>().props;

  return <BalancePage {...payout_presenter} />;
}

export default index;
