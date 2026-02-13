import { usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { Profile, Props as ProfileProps } from "$app/components/server-components/Profile";

type Props = ProfileProps;

export default function ShowPage() {
  const { ...profileProps } = cast<Props>(usePage().props);

  return (
    <>
      <Profile {...profileProps} />
    </>
  );
}

ShowPage.loggedInUserLayout = true;
