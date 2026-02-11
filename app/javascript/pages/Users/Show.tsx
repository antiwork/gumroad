import { usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { Profile, Props as ProfileProps } from "$app/components/server-components/Profile";

export default function UserShowPage() {
  const props = cast<ProfileProps>(usePage().props);

  return <Profile {...props} />;
}
UserShowPage.loggedInUserLayout = true;
