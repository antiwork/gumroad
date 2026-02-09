import { usePage } from "@inertiajs/react";
import * as React from "react";

import { Profile, Props as ProfileProps } from "$app/components/server-components/Profile";
import BasePage from "$app/utils/base_page";

type Props = ProfileProps & {
  card_data_handling_mode: string;
  paypal_merchant_currency: string;
};

// Module-level variable to ensure initialization only runs once per session
let initialized = false;

export default function UsersShowPage() {
  const props = usePage<Props>().props;

  React.useEffect(() => {
    if (!initialized) {
      BasePage.initialize();
      initialized = true;
    }
  }, []);

  return (
    <div className="flex h-screen flex-col overflow-y-auto">
      <Profile {...props} />
    </div>
  );
}

UsersShowPage.loggedInUserLayout = true;
