import { usePage } from "@inertiajs/react";
import React from "react";

import { default as CustomerDetailPage, CustomerDetailPageProps } from "$app/components/Audience/CustomerDetailPage";

function show() {
  const props = usePage<CustomerDetailPageProps>().props;

  return <CustomerDetailPage {...props} />;
}

export default show;
