import { usePage } from "@inertiajs/react";
import React from "react";
import { cast } from "ts-safe-cast";

import PaymentsPage, { type PaymentPagePropType } from "$app/components/server-components/Settings/PaymentsPage";

export default function Index() {
  const props = cast<PaymentPagePropType>(usePage().props);

  return <PaymentsPage {...props} />;
}
