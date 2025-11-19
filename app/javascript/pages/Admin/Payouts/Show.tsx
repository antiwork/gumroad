import { usePage } from "@inertiajs/react";
import React from "react";
import { cast } from "ts-safe-cast";

import AdminPayout, { type Payout } from "$app/components/Admin/Payouts/Payout";

type Props = {
  payout: Payout;
};

const AdminPayoutsShow = () => {
  const { payout } = cast<Props>(usePage().props);

  return (
    <div className="flex flex-col gap-4">
      <AdminPayout payout={payout} />
    </div>
  );
};

export default AdminPayoutsShow;
