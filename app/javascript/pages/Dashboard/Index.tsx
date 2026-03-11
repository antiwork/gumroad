import { Deferred, usePage } from "@inertiajs/react";
import React from "react";

import { DashboardPage, type DashboardPageProps } from "$app/components/DashboardPage";

type DashboardData = {
  balances: NonNullable<DashboardPageProps["balances"]>;
  sales: NonNullable<DashboardPageProps["sales"]>;
  activity_items: NonNullable<DashboardPageProps["activity_items"]>;
};

type PageProps = Omit<DashboardPageProps, "balances" | "sales" | "activity_items"> & {
  dashboard_data: DashboardData;
};

function Dashboard() {
  const { dashboard_data, ...props } = usePage<PageProps>().props;

  return (
    <Deferred data={["dashboard_data"]} fallback={<DashboardPage {...props} />}>
      <DashboardPage {...props} {...dashboard_data} />
    </Deferred>
  );
}

export default Dashboard;
