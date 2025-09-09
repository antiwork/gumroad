import { usePage } from "@inertiajs/react";
import React from "react";

import { default as DashboardPage, DashboardPageProps } from "$app/components/server-components/DashboardPage";

function Dashboard() {
  const { creator_home } = usePage<{ creator_home: DashboardPageProps }>().props;

  return <DashboardPage {...creator_home} />;
}

export default Dashboard;
