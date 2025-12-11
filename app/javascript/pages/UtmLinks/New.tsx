import { usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import type { UtmLinkFormProps } from "$app/types/utm_link";

import { UtmLinkForm } from "$app/components/UtmLinksPage/UtmLinkForm";

export default function UtmLinksNew() {
  const props = cast<UtmLinkFormProps>(usePage().props);

  return <UtmLinkForm context={props.context} utm_link={props.utm_link} />;
}
