import { Head, usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { CreatorProfile } from "$app/parsers/profile";

import { Product, Purchase } from "$app/components/Product";
import { Layout } from "$app/components/Profile/Layout";
import { CoffeeProduct } from "$app/components/server-components/Profile/CoffeePage";

type PageProps = {
  product: Product;
  purchase: Purchase | null;
  creator_profile: CreatorProfile;
  custom_styles: string;
};

function CoffeePage() {
  const { product, purchase, creator_profile, custom_styles } = cast<PageProps>(usePage().props);

  return (
    <>
      <Head>
        <style>{custom_styles}</style>
      </Head>
      <div className="coffee-page-wrapper">
        <Layout creatorProfile={creator_profile} hideFollowForm>
          <CoffeeProduct product={product} purchase={purchase} className="mx-auto w-full max-w-6xl lg:px-0" />
        </Layout>
      </div>
    </>
  );
}

CoffeePage.loggedInUserLayout = true;
export default CoffeePage;
