import React from "react";
import { usePage } from "@inertiajs/react";

import { Taxonomy } from "$app/utils/discover";
import { Layout as DiscoverLayout } from "$app/components/Discover/Layout";
import { Layout, Props } from "$app/components/Product/Layout";

type PageProps = Props & { taxonomy_path: string | null; taxonomies_for_nav: Taxonomy[] };

function Discover() {
  const props = usePage<{ props: PageProps }>().props as unknown as PageProps;

  return (
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
}

export default Discover;
