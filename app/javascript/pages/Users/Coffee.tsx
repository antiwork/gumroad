import { usePage } from "@inertiajs/react";
import * as React from "react";
import typia from "typia";

import { incrementProductViews } from "$app/data/view_event";
import { CreatorProfile } from "$app/parsers/profile";

import { Product, Purchase } from "$app/components/Product";
import { CoffeeProduct } from "$app/components/Product/CoffeeProduct";
import { Layout as ProfileLayout } from "$app/components/Profile/Layout";
import { useOriginalLocation } from "$app/components/useOriginalLocation";
import { useRunOnce } from "$app/components/useRunOnce";

type Props = {
  product: Product;
  purchase: Purchase | null;
  creator_profile: CreatorProfile;
};

export default function CoffeePage() {
  const { product, purchase, creator_profile } = typia.assert<Props>(usePage().props);
  const { searchParams } = new URL(useOriginalLocation());

  // The coffee page is served from /coffee rather than /l/:permalink, so nothing else records its
  // views and the seller's analytics stay at zero. Same call the standard product page makes.
  useRunOnce(() => {
    void incrementProductViews({ permalink: product.permalink, recommendedBy: searchParams.get("recommended_by") });
  });

  return (
    <ProfileLayout
      creatorProfile={creator_profile}
      hideFollowForm
      currencySelector
      shownCurrency={product.buyer_currency_display?.buyer_currency_shown}
    >
      {/* Gutter outside the cap, as SectionLayout has it. Must stay a growing flex child:
          CoffeeProduct's `grow content-center` only fills the page while its parent grows. */}
      <div className="flex grow flex-col px-4">
        <CoffeeProduct product={product} purchase={purchase} className="mx-auto w-full max-w-6xl" />
      </div>
    </ProfileLayout>
  );
}
CoffeePage.loggedInUserLayout = true;
