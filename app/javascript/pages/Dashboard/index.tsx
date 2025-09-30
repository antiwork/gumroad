import { usePage } from "@inertiajs/react";
import React from "react";

import { default as DashboardPage, DashboardPageProps } from "$app/components/DashboardPage";

function Dashboard() {
  const {
    name,
    has_sale,
    getting_started_stats,
    sales,
    balances,
    activity_items,
    stripe_verification_message,
    tax_forms,
    show_1099_download_notice,
  } = usePage<DashboardPageProps>().props;

  return (
    <DashboardPage
      name={name}
      has_sale={has_sale}
      getting_started_stats={getting_started_stats}
      sales={sales}
      balances={balances}
      activity_items={activity_items}
      stripe_verification_message={stripe_verification_message}
      tax_forms={tax_forms}
      show_1099_download_notice={show_1099_download_notice}
    />
  );
}

export default Dashboard;
