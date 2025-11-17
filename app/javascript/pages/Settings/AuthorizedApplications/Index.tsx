import { usePage } from "@inertiajs/react";
import React from "react";
import { cast } from "ts-safe-cast";

import AuthorizedApplicationsPage, {
  type AuthorizedApplicationsPagePropsType,
} from "$app/components/server-components/Settings/AuthorizedApplicationsPage";

export default function Index() {
  const props = cast<AuthorizedApplicationsPagePropsType>(usePage().props);

  return <AuthorizedApplicationsPage {...props} />;
}
