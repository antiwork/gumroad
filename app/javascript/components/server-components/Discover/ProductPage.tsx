import * as React from "react";
import { createCast } from "ts-safe-cast";

import { Taxonomy } from "$app/utils/discover";
import { register } from "$app/utils/serverComponentUtil";

import { Layout as DiscoverLayout } from "$app/components/Discover/Layout";
import { Layout, Props } from "$app/components/Product/Layout";

const ProductPage = (props: Props & { taxonomy_path: string | null; taxonomies_for_nav: Taxonomy[] }) => (
  <DiscoverLayout
    taxonomyPath={props.taxonomy_path ?? undefined}
    taxonomiesForNav={props.taxonomies_for_nav}
    forceDomain
  >
    <Layout cart hasHero {...props} />
    {/* render an empty div for the add section button */}
    {"products" in props ? <div /> : null}
  </DiscoverLayout>
);

export default register({ component: ProductPage, propParser: createCast() });
