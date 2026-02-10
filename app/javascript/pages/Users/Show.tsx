import { Head, usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { Profile, Props as ProfileProps } from "$app/components/server-components/Profile";

type Props = ProfileProps & {
  custom_styles: string;
};

export default function UserPage() {
  const { custom_styles, ...profileProps } = cast<Props>(usePage().props);

  return (
    <>
      <Head>
        <style>{custom_styles}</style>
      </Head>
      <Profile {...profileProps} />
    </>
  );
}
UserPage.loggedInUserLayout = true;
