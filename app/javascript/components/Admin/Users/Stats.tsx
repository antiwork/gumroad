import * as React from "react";
import { cast } from "ts-safe-cast";

import { request, assertResponseError } from "$app/utils/request";

import Loading from "$app/components/Admin/Loading";
import { showAlert } from "$app/components/server-components/Alert";
import { useIsIntersecting } from "$app/components/useIsIntersecting";

type UserStatsProps = {
  total: string;
  balance: string;
  chargeback_volume: string;
  chargeback_count: string;
};

type ResponseData = {
  total: string;
  balance: string;
  chargeback_volume: string;
  chargeback_count: string;
};

const AdminUserStats = ({ user_id }: { user_id: number }) => {
  const [userStats, setUserStats] = React.useState<UserStatsProps | null>(null);

  const elementRef = useIsIntersecting<HTMLUListElement>((isIntersecting) => {
    if (!isIntersecting || userStats) return;

    const fetchUserStats = async () => {
      try {
        const response = await request({
          method: "GET",
          url: Routes.admin_user_stats_path(user_id),
          accept: "json",
        });
        if (!response.ok) assertResponseError(response);
        const data = cast<ResponseData>(await response.json());
        setUserStats(data);
      } catch (e) {
        assertResponseError(e);
        showAlert(e.message, "error");
      }
    };

    void fetchUserStats();
  });

  return (
    <ul ref={elementRef} className="inline">
      <li>{userStats ? `${userStats.total} total` : <Loading />}</li>
      <li>{userStats ? `${userStats.balance} balance` : <Loading />}</li>
      <li>{userStats ? `${userStats.chargeback_volume} vol CB` : <Loading />}</li>
      <li>{userStats ? `${userStats.chargeback_count} count CB` : <Loading />}</li>
    </ul>
  );
};

export default AdminUserStats;
