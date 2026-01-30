import { usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import {
  ProductPageAlert,
  ProductPageHead,
  ProductPageMeta,
  ProductPageNoScript,
} from "$app/pages/Products/ProductPageHead";

import { Layout as ProductLayout, Props as ProductLayoutProps } from "$app/components/Product/Layout";
import { Layout as ProfileLayout } from "$app/components/Profile/Layout";

type ProfileProductShowPageProps = {
  product: ProductLayoutProps;
  meta: ProductPageMeta;
};

const ProfileProductShowPage = () => {
  const { product, meta } = cast<ProfileProductShowPageProps>(usePage().props);

  return (
    <>
      <ProductPageHead meta={meta} />
      <ProductPageNoScript />
      <ProductPageAlert />
      <ProfileLayout creatorProfile={product.creator_profile}>
        <ProductLayout cart {...product} />
      </ProfileLayout>
    </>
  );
};

ProfileProductShowPage.loggedInUserLayout = true;

export default ProfileProductShowPage;
