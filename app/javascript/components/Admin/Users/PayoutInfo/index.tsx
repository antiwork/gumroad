import React from "react";
import { cast } from "ts-safe-cast";

import { request } from "$app/utils/request";

import PayoutInfo, { type PayoutInfoProps } from "$app/components/Admin/Users/PayoutInfo/PayoutInfo";
import type { User } from "$app/components/Admin/Users/User";
import { useIsIntersecting } from "$app/components/useIsIntersecting";

type AdminUserPayoutInfoProps = {
  user: User;
};

const AdminUserPayoutInfo = ({ user }: AdminUserPayoutInfoProps) => {
  const [isLoading, setIsLoading] = React.useState(false);
  const [data, setData] = React.useState<PayoutInfoProps | null>(null);

  const elementRef = useIsIntersecting<HTMLDivElement>((isIntersecting) => {
    if (!isIntersecting || data) return;

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

    void fetchPayoutInfo();
  });

  return (
    <div ref={elementRef}>
      <h3>Payout Info</h3>
      <PayoutInfo user_id={user.id} payoutInfo={data} isLoading={isLoading} />
    </div>
  );
};

export default AdminUserPayoutInfo;
