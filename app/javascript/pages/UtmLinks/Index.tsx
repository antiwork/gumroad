import { usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import type { UtmLinksIndexProps } from "$app/types/utm_link";

import UtmLinkList from "$app/components/UtmLinksPage/UtmLinkList";

export default function UtmLinksIndex() {
  const props = cast<UtmLinksIndexProps>(usePage().props);

  return <UtmLinkList {...props} />;
}
