import { Head, usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { CreatorProfile } from "$app/parsers/profile";
import { Props as ProductProps } from "$app/components/Product";
import { PriceSelection } from "$app/components/Product/ConfigurationSelector";
import { CoffeeProduct } from "$app/components/server-components/Profile/CoffeePage";
import { Layout as ProfileLayout } from "$app/components/Profile/Layout";

type Props = ProductProps & {
  creator_profile: CreatorProfile;
  selection?: Partial<PriceSelection>;
};

export default function Coffee() {
  const { creator_profile, selection, ...productProps } = cast<Props>(usePage().props);

  return (
    <>
      <Head>
        <title>{productProps.product.name}</title>
      </Head>

      <ProfileLayout creatorProfile={creator_profile} hideFollowForm>
        <CoffeeProduct
          product={productProps.product}
          purchase={productProps.purchase}
          selection={selection ?? null}
          className="mx-auto w-full max-w-6xl lg:px-0"
        />
      </ProfileLayout>
    </>
  );
}

Coffee.loggedInUserLayout = true;
