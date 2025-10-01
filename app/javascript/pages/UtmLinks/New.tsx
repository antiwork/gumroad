import { usePage } from "@inertiajs/react";
import React from "react";

import { UtmLinksPageProps } from "$app/components/UtmLinksPage";
import { UtmLinkForm } from "$app/components/UtmLinksPage/UtmLinkForm";

function UtmLinks() {
  const { context, utm_link, copy_from } = usePage<UtmLinksPageProps>().props;

  return <UtmLinkForm context={context} utm_link={utm_link ?? null} {...(copy_from && { copy_from })} />;
}

export default UtmLinks;
