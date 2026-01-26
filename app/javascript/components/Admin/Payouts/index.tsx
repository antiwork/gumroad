import React from "react";

import AdminPayout, { type Payout } from "$app/components/Admin/Payouts/Payout";

type Props = {
  payouts: Payout[];
};

const AdminPayouts = ({ payouts }: Props) => (
  <>
    {payouts.map((payout) => (
      <AdminPayout key={payout.external_id} payout={payout} />
    ))}
  </>
);

export default AdminPayouts;
