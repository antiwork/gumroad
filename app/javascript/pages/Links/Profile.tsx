import React from "react";
import { usePage } from "@inertiajs/react";

import { CreatorProfile } from "$app/parsers/profile";
import { Layout as ProductLayout, Props } from "$app/components/Product/Layout";
import { Layout as ProfileLayout } from "$app/components/Profile/Layout";

type PageProps = Props & { creator_profile: CreatorProfile };

function Profile() {
  const props = usePage<{ props: PageProps }>().props as unknown as PageProps;

  return (
    <ProfileLayout creatorProfile={props.creator_profile}>
      <ProductLayout cart {...props} />
    </ProfileLayout>
  );
}

export default Profile;
