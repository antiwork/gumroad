import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import { Layout as ProductLayout, Props } from "$app/components/Product/Layout";
import { Layout as ProfileLayout } from "$app/components/Profile/Layout";

const ProductPage = (props: Props) => (
  <ProfileLayout creatorProfile={props.creator_profile}>
    <ProductLayout cart {...props} />
  </ProfileLayout>
);

export default register({ component: ProductPage, propParser: createCast() });
