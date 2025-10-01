import { usePage } from "@inertiajs/react";
import React from "react";

import { UtmLinksPageProps } from "$app/components/UtmLinksPage";
import { UtmLinkForm } from "$app/components/UtmLinksPage/UtmLinkForm";

function UtmLinks() {
  const { context, utm_link } = usePage<UtmLinksPageProps>().props;

  return <UtmLinkForm context={context} utm_link={utm_link ?? null} />;
}

export default UtmLinks;
