import * as React from "react";

import { StandaloneLayout } from "$app/inertia/layout";
import { CreatorProfile } from "$app/parsers/profile";

import { FollowFormBlock } from "$app/components/Profile/FollowForm";
import { Layout } from "$app/components/Profile/Layout";

type PageProps = {
  creator_profile: CreatorProfile;
};

function ProfileSubscribe({ creator_profile }: PageProps) {
  return (
    <div className="flex min-h-full min-w-full flex-1 flex-col">
      <Layout hideFollowForm creatorProfile={creator_profile}>
        <FollowFormBlock creatorProfile={creator_profile} className="px-4" />
      </Layout>
    </div>
  );
}

ProfileSubscribe.layout = (page: React.ReactNode) => <StandaloneLayout>{page}</StandaloneLayout>;

export default ProfileSubscribe;
