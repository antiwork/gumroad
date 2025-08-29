import { usePage } from "@inertiajs/react";
import React from "react";

import { default as AnalyticsPage, AnalyticsPageProps } from "$app/components/server-components/AnalyticsPage";

function Analytics() {
  const { analytics_props } = usePage<{ analytics_props: AnalyticsPageProps }>().props;

  return <AnalyticsPage {...analytics_props} />;
}

export default Analytics;
