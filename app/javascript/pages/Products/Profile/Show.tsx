import { usePage } from "@inertiajs/react";
import * as React from "react";
import typia from "typia";

import { CreatorProfile } from "$app/parsers/profile";

import { Layout as ProductLayout, Props } from "$app/components/Product/Layout";
import { Layout as ProfileLayout } from "$app/components/Profile/Layout";

type PageProps = Props & {
  creator_profile: CreatorProfile;
};

function ProfileProductShowPage() {
  const props = typia.assert<PageProps>(usePage().props);

  return (
    <ProfileLayout creatorProfile={props.creator_profile}>
      <ProductLayout cart {...props} />
    </ProfileLayout>
  );
}

ProfileProductShowPage.loggedInUserLayout = true;
export default ProfileProductShowPage;
