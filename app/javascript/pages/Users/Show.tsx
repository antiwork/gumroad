import { usePage } from "@inertiajs/react";
import * as React from "react";

import { Profile, Props as ProfileProps } from "$app/components/Profile";

export default function UsersShowPage() {
  const props = usePage<ProfileProps>().props;

  return (
    <div className="flex h-screen flex-col overflow-y-auto">
      <Profile {...props} />
    </div>
  );
}

UsersShowPage.loggedInUserLayout = true;
