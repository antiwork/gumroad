import { usePage } from "@inertiajs/react";
import * as React from "react";

import { CreatorProfile } from "$app/parsers/profile";
import { cast } from "$app/utils/cast";

import { Layout as ProductLayout, Props } from "$app/components/Product/Layout";
import { Layout as ProfileLayout } from "$app/components/Profile/Layout";

type PageProps = Props & {
  creator_profile: CreatorProfile;
};

function ProfileProductShowPage() {
  const props = cast<PageProps>(usePage().props);

  return (
    <ProfileLayout
      creatorProfile={props.creator_profile}
      currencySelector
      shownCurrency={props.product.buyer_currency_display?.buyer_currency_shown}
    >
      {/* The profile header above already shows the seller's avatar and name. */}
      <ProductLayout cart hideSellerByline {...props} />
    </ProfileLayout>
  );
}

ProfileProductShowPage.loggedInUserLayout = true;
export default ProfileProductShowPage;
