import { usePage } from "@inertiajs/react";
import React from "react";

import { default as AnalyticsPage, AnalyticsPageProps } from "$app/components/AnalyticsPage";

function Analytics() {
  const { products, country_codes, state_names } = usePage<AnalyticsPageProps>().props;

  return <AnalyticsPage products={products} country_codes={country_codes} state_names={state_names} />;
}

export default Analytics;
