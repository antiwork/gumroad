import { usePage } from "@inertiajs/react";
import * as React from "react";
import typia from "typia";

import { Profile } from "$app/components/Profile";

type ShowPageProps = React.ComponentProps<typeof Profile>;

function UsersShow() {
  const profileProps = typia.assert<ShowPageProps>(usePage().props);
  return <Profile {...profileProps} />;
}

UsersShow.loggedInUserLayout = true;

export default UsersShow;
