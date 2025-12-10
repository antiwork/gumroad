import * as React from "react";
import { createCast } from "ts-safe-cast";

import { CreatorProfile } from "$app/parsers/profile";
import { register } from "$app/utils/serverComponentUtil";

import { FollowFormBlock } from "$app/components/Profile/FollowForm";
import { Layout } from "$app/components/Profile/Layout";

type Props = { creator_profile: CreatorProfile };

const SubscribePage = ({ creator_profile }: Props) => (
  <Layout hideFollowForm creatorProfile={creator_profile}>
    <FollowFormBlock creatorProfile={creator_profile} className="px-4" />
  </Layout>
);

export default register({ component: SubscribePage, propParser: createCast() });
