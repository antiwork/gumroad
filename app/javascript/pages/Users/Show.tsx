import { usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { Profile } from "$app/components/Profile";

type ShowPageProps = React.ComponentProps<typeof Profile>;

function UsersShow() {
  const profileProps = cast<ShowPageProps>(usePage().props);
  return <Profile {...profileProps} />;
}

UsersShow.loggedInUserLayout = true;

export default UsersShow;
