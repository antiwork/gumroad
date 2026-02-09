import { usePage } from "@inertiajs/react";
import * as React from "react";

import { CreatorProfile } from "$app/parsers/profile";
import { FollowFormBlock } from "$app/components/Profile/FollowForm";
import { Layout } from "$app/components/Profile/Layout";
import BasePage from "$app/utils/base_page";

type Props = {
  creator_profile: CreatorProfile;
};

// Module-level variable to ensure initialization only runs once per session
let initialized = false;

export default function UsersSubscribePage() {
  const { creator_profile } = usePage<Props>().props;

  React.useEffect(() => {
    if (!initialized) {
      BasePage.initialize();
      initialized = true;
    }
  }, []);

  return (
    <div className="flex h-screen flex-col overflow-y-auto">
      <Layout hideFollowForm creatorProfile={creator_profile}>
        <FollowFormBlock creatorProfile={creator_profile} className="px-4" />
      </Layout>
    </div>
  );
}

UsersSubscribePage.loggedInUserLayout = true;
