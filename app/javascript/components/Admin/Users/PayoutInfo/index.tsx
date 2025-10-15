import React from "react";
import { cast } from "ts-safe-cast";

import { request } from "$app/utils/request";

import PayoutInfo, { type PayoutInfoProps } from "$app/components/Admin/Users/PayoutInfo/PayoutInfo";
import type { User } from "$app/components/Admin/Users/User";

type AdminUserPayoutInfoProps = {
  user: User;
};

const AdminUserPayoutInfo = ({ user }: AdminUserPayoutInfoProps) => {
  const [open, setOpen] = React.useState(false);
  const [isLoading, setIsLoading] = React.useState(false);
  const [data, setData] = React.useState<PayoutInfoProps | null>(null);

  const fetchPayoutInfo = async () => {
    setIsLoading(true);
    const response = await request({
      method: "GET",
      url: Routes.admin_user_payout_info_path(user.id),
      accept: "json",
    });
    setData(cast<PayoutInfoProps>(await response.json()));
    setIsLoading(false);
  };

  const onToggle = (e: React.MouseEvent<HTMLDetailsElement>) => {
    setOpen(e.currentTarget.open);
    if (e.currentTarget.open) {
      void fetchPayoutInfo();
    }
  };

  return (
    <>
      <hr />
      <details open={open} onToggle={onToggle}>
        <summary>
          <h3>Payout Info</h3>
        </summary>
        <PayoutInfo user_id={user.id} payoutInfo={data} isLoading={isLoading} />
      </details>
    </>
  );
};

export default AdminUserPayoutInfo;
