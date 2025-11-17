import { usePage } from "@inertiajs/react";
import React from "react";
import { cast } from "ts-safe-cast";

import TeamPage, { type TeamPageProps } from "$app/components/server-components/Settings/TeamPage";

export default function Index() {
  const props = cast<TeamPageProps>(usePage().props);

  return <TeamPage {...props} />;
}
