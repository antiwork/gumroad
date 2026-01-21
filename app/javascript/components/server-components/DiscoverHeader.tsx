import * as React from "react";
import { createCast } from "ts-safe-cast";

import { Taxonomy } from "$app/utils/discover";

import { Layout } from "$app/components/Discover/Layout";
import { register } from "$app/utils/serverComponentUtil";

type Props = {
  taxonomies_for_nav: Taxonomy[];
};

const DiscoverHeader = ({ taxonomies_for_nav }: Props) => (
  <Layout
    taxonomiesForNav={taxonomies_for_nav}
    forceDomain={true}
  >
    {null}
  </Layout>
);

export default register({ component: DiscoverHeader, propParser: createCast() });
