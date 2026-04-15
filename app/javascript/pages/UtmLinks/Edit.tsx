import { usePage } from "@inertiajs/react";
import * as React from "react";

import { UtmLinkForm, type UtmLinkEditProps } from "$app/components/UtmLinks/UtmLinkForm";

export default function UtmLinksEdit() {
  const props = usePage<UtmLinkEditProps>().props;
  return <UtmLinkForm {...props} />;
}
