import { usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import {
  ProductPageAlert,
  ProductPageHead,
  ProductPageMeta,
  ProductPageNoScript,
} from "$app/pages/Products/ProductPageHead";

import { PoweredByFooter } from "$app/components/PoweredByFooter";
import { Layout, Props as ProductLayoutProps } from "$app/components/Product/Layout";

type ProductShowPageProps = {
  product: ProductLayoutProps;
  meta: ProductPageMeta;
};

const ProductShowPage = () => {
  const { product, meta } = cast<ProductShowPageProps>(usePage().props);

  return (
    <>
      <ProductPageHead meta={meta} />
      <ProductPageNoScript />
      <ProductPageAlert />
      <Layout {...product} />
      <PoweredByFooter />
    </>
  );
};

ProductShowPage.loggedInUserLayout = true;

export default ProductShowPage;
