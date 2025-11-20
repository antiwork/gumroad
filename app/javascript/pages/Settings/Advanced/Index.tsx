import { usePage } from "@inertiajs/react";
import React from "react";
import { cast } from "ts-safe-cast";

import AdvancedPage, { type AdvancedSettingsPropsType } from "$app/components/server-components/Settings/AdvancedPage";

export default function Index() {
  const props = cast<AdvancedSettingsPropsType>(usePage().props);

  return <AdvancedPage {...props} />;
}
