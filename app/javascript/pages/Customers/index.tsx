import { usePage } from "@inertiajs/react";
import React from "react";

import { default as CustomersPage, CustomerPageProps } from "$app/components/server-components/Audience/CustomersPage";

function index() {
  const { customers_presenter } = usePage<{ customers_presenter: CustomerPageProps }>().props;

  return <CustomersPage {...customers_presenter} />;
}

export default index;
