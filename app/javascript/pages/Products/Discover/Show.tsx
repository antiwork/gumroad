import { usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { Taxonomy } from "$app/utils/discover";

import { Layout as DiscoverLayout } from "$app/components/Discover/Layout";
import { Layout, Props as ProductLayoutProps } from "$app/components/Product/Layout";

import { ProductPageAlert, ProductPageHead, ProductPageMeta, ProductPageNoScript } from "$app/pages/Products/ProductPageHead";

type DiscoverProductShowPageProps = {
  product: ProductLayoutProps & { taxonomy_path: string | null; taxonomies_for_nav: Taxonomy[] };
  meta: ProductPageMeta;
  title: string;
};

const DiscoverProductShowPage = () => {
  const { product, meta, title } = cast<DiscoverProductShowPageProps>(usePage().props);

  return (
    <>
      <ProductPageHead meta={meta} title={title} />
      <ProductPageNoScript />
      <ProductPageAlert />
      <DiscoverLayout
        taxonomyPath={product.taxonomy_path ?? undefined}
        taxonomiesForNav={product.taxonomies_for_nav}
        forceDomain
      >
        <Layout cart hasHero {...product} />
        {"products" in product ? <div /> : null}
      </DiscoverLayout>
    </>
  );
};

DiscoverProductShowPage.disableLayout = true;

export default DiscoverProductShowPage;
