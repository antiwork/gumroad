import { usePage } from "@inertiajs/react";
import React from "react";
import { cast } from "ts-safe-cast";

import ThirdPartyAnalyticsPage, {
  type ThirdPartyAnalyticsPagePropsType,
} from "$app/components/server-components/Settings/ThirdPartyAnalyticsPage";

export default function Index() {
  const props = cast<ThirdPartyAnalyticsPagePropsType>(usePage().props);

  return <ThirdPartyAnalyticsPage {...props} />;
}
