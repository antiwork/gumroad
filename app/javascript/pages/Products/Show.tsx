import { usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { PoweredByFooter } from "$app/components/PoweredByFooter";
import { Layout, Props as ProductLayoutProps } from "$app/components/Product/Layout";

import { ProductPageAlert, ProductPageHead, ProductPageMeta, ProductPageNoScript } from "$app/pages/Products/ProductPageHead";

type ProductShowPageProps = {
  product: ProductLayoutProps;
  meta: ProductPageMeta;
  title: string;
};

const ProductShowPage = () => {
  const { product, meta, title } = cast<ProductShowPageProps>(usePage().props);

  return (
    <>
      <ProductPageHead meta={meta} title={title} />
      <ProductPageNoScript />
      <ProductPageAlert />
      <Layout {...product} />
      <PoweredByFooter />
    </>
  );
};

ProductShowPage.disableLayout = true;

export default ProductShowPage;
