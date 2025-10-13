import { usePage } from "@inertiajs/react";
import React from "react";

import Payouts, { type PayoutsProps } from "$app/components/Payouts";

function index() {
  const { payout_presenter } = usePage<{ payout_presenter: PayoutsProps }>().props;

  return <Payouts {...payout_presenter} />;
}

export default index;
