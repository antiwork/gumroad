import { usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { Layout as ProductLayout, Props as ProductLayoutProps } from "$app/components/Product/Layout";
import { Layout as ProfileLayout } from "$app/components/Profile/Layout";

import { ProductPageAlert, ProductPageHead, ProductPageMeta, ProductPageNoScript } from "$app/pages/Products/ProductPageHead";

type ProfileProductShowPageProps = {
  product: ProductLayoutProps;
  meta: ProductPageMeta;
  title: string;
};

const ProfileProductShowPage = () => {
  const { product, meta, title } = cast<ProfileProductShowPageProps>(usePage().props);

  return (
    <>
      <ProductPageHead meta={meta} title={title} />
      <ProductPageNoScript />
      <ProductPageAlert />
      <ProfileLayout creatorProfile={product.creator_profile}>
        <ProductLayout cart {...product} />
      </ProfileLayout>
    </>
  );
};

ProfileProductShowPage.disableLayout = true;

export default ProfileProductShowPage;
