import { usePage } from "@inertiajs/react";
import * as React from "react";

import { UtmLinkForm, type UtmLinkFormProps } from "$app/components/UtmLinks/UtmLinkForm";

export default function UtmLinksNew() {
  const props = usePage<UtmLinkFormProps>().props;
  return <UtmLinkForm {...props} />;
}
