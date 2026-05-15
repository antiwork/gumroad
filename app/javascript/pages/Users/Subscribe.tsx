import { usePage } from "@inertiajs/react";
import * as React from "react";
import typia from "typia";

import { CreatorProfile } from "$app/parsers/profile";

import { FollowUserFormBlock } from "$app/components/Profile/FollowUserForm";
import { Layout } from "$app/components/Profile/Layout";

type SubscribePageProps = {
  creator_profile: CreatorProfile;
};

export default function UsersSubscribe() {
  const { creator_profile } = typia.assert<SubscribePageProps>(usePage().props);
  return (
    <Layout hideFollowForm creatorProfile={creator_profile}>
      <FollowUserFormBlock creatorProfile={creator_profile} className="px-4" />
    </Layout>
  );
}
UsersSubscribe.loggedInUserLayout = true;
