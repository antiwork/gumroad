import { usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { UtmLinkNewPageProps } from "$app/data/utm_links";

import { UtmLinkForm } from "$app/components/UtmLinks/UtmLinkForm";

export default function UtmLinksNew() {
  const { context, utm_link } = cast<UtmLinkNewPageProps>(usePage().props);
  return <UtmLinkForm context={context} utm_link={utm_link} />;
}
