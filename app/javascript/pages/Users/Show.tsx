import { usePage } from "@inertiajs/react";
import * as React from "react";

import { Profile, Props as ProfileProps } from "$app/components/server-components/Profile";

type Props = ProfileProps & {
  card_data_handling_mode: string;
  paypal_merchant_currency: string;
};

export default function UsersShowPage() {
  const props = usePage<Props>().props;

  return (
    <div className="flex h-screen flex-col overflow-y-auto">
      <Profile {...props} />
    </div>
  );
}

UsersShowPage.loggedInUserLayout = true;
