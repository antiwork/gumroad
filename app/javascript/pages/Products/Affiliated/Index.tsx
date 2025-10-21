import { usePage } from "@inertiajs/react";
import React from "react";

import { default as AffiliatedPage, type AffiliatedPageProps } from "$app/components/AffiliatedPage";

function Affiliated() {
  const props = usePage<AffiliatedPageProps>().props;

  return <AffiliatedPage {...props} />;
}

export default Affiliated;
