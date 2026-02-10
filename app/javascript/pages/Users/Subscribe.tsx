import { Head, usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { CreatorProfile } from "$app/parsers/profile";

import { FollowFormBlock } from "$app/components/Profile/FollowForm";
import { Layout } from "$app/components/Profile/Layout";

type Props = {
  creator_profile: CreatorProfile;
  custom_styles: string;
};

export default function SubscribePage() {
  const { creator_profile, custom_styles } = cast<Props>(usePage().props);

  return (
    <>
      <Head>
        <style>{custom_styles}</style>
      </Head>
      <Layout hideFollowForm creatorProfile={creator_profile}>
        <FollowFormBlock creatorProfile={creator_profile} className="px-4" />
      </Layout>
    </>
  );
}
SubscribePage.loggedInUserLayout = true;
