import { usePage } from "@inertiajs/react";
import React from "react";

import TaxCenterPage, { type TaxCenterPageProps } from "$app/components/TaxCenter";

function index() {
  const props = usePage<TaxCenterPageProps>().props;

  return <TaxCenterPage {...props} />;
}

export default index;
