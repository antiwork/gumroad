import { usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { CreatorProfile } from "$app/parsers/profile";

import { Product, Purchase } from "$app/components/Product";
import { CoffeeProduct } from "$app/components/Product/CoffeeProduct";
import { Layout as ProfileLayout } from "$app/components/Profile/Layout";

type Props = {
  product: Product;
  purchase: Purchase | null;
  creator_profile: CreatorProfile;
};

export default function CoffeePage() {
  const { product, purchase, creator_profile } = cast<Props>(usePage().props);

  return (
    <ProfileLayout creatorProfile={creator_profile} hideFollowForm>
      <CoffeeProduct product={product} purchase={purchase} className="mx-auto w-full max-w-6xl lg:px-0" />
    </ProfileLayout>
  );
}
CoffeePage.loggedInUserLayout = true;
