import { usePage } from "@inertiajs/react";
import React from "react";

import { default as UtmLinksPage, UtmLinksPageProps } from "$app/components/UtmLinksPage";

function UtmLinks() {
  const { utm_links, pagination, context, utm_link, copy_from } = usePage<UtmLinksPageProps>().props;

  return (
    <UtmLinksPage
      utm_links={utm_links}
      pagination={pagination}
      context={context}
      utm_link={utm_link}
      copy_from={copy_from}
    />
  );
}

export default UtmLinks;
