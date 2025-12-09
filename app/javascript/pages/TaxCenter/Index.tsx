import { usePage } from "@inertiajs/react";
import React from "react";

import TaxCenterPage, { type TaxCenterPageProps } from "$app/components/TaxCenter";

function index() {
  const { tax_center_presenter } = usePage<{ tax_center_presenter: TaxCenterPageProps }>().props;

  return <TaxCenterPage {...tax_center_presenter} />;
}

export default index;
