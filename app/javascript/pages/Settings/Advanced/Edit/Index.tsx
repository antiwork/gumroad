import { usePage } from "@inertiajs/react";
import React from "react";
import { cast } from "ts-safe-cast";

import EditApplicationPage, {
  type EditAdvancedSettingsPropsType,
} from "$app/components/server-components/Settings/AdvancedApplicationEditPage";

export default function Index() {
  const props = cast<EditAdvancedSettingsPropsType>(usePage().props);

  return <EditApplicationPage {...props} />;
}
