import { usePage } from "@inertiajs/react";
import React from "react";
import typia from "typia";

import AdminPayout, { type Payout } from "$app/components/Admin/Payouts/Payout";

type Props = {
  payout: Payout;
};

const AdminPayoutsShow = () => {
  const { payout } = typia.assert<Props>(usePage().props);

  return (
    <div className="flex flex-col gap-4">
      <AdminPayout payout={payout} />
    </div>
  );
};

export default AdminPayoutsShow;
