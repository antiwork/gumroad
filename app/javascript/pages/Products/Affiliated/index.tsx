import { usePage } from "@inertiajs/react";
import React from "react";

import { default as AffiliatedPage, AffiliatedPageProps } from "$app/components/server-components/AffiliatedPage";

function Affiliated() {
  const { affiliated_page_props } = usePage<{ affiliated_page_props: AffiliatedPageProps }>().props;

  return <AffiliatedPage {...affiliated_page_props} />;
}

export default Affiliated;
