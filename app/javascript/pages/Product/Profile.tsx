import { usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { Layout as ProductLayout, Props } from "$app/components/Product/Layout";
import { Layout as ProfileLayout } from "$app/components/Profile/Layout";

export default function ProfileProductPage() {
  const props = cast<Props>(usePage().props);

  return (
    <ProfileLayout creatorProfile={props.creator_profile}>
      <ProductLayout cart {...props} />
    </ProfileLayout>
  );
}
