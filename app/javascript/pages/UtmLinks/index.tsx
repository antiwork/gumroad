import { usePage } from "@inertiajs/react";
import React from "react";

import { default as UtmLinksPage, UtmLinksPageProps } from "$app/components/server-components/UtmLinksPage";

function UtmLinks() {
  const { utm_links_props } = usePage<{ utm_links_props: UtmLinksPageProps }>().props;

  return <UtmLinksPage {...utm_links_props} />;
}

export default UtmLinks;
