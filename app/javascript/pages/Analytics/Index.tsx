import { usePage } from "@inertiajs/react";
import React from "react";

import { default as AnalyticsPage, AnalyticsProps as AnalyticsPageProps } from "$app/components/Analytics";

function Analytics() {
  const { analytics_props } = usePage<{ analytics_props: AnalyticsPageProps }>().props;

  return <AnalyticsPage {...analytics_props} />;
}

export default Analytics;
