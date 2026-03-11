import { Deferred, usePage } from "@inertiajs/react";
import React from "react";

import { CustomersContentLoading } from "$app/components/Audience/CustomersContentLoading";
import { default as CustomersPage, CustomerPageProps } from "$app/components/Audience/CustomersPage";

function CustomersContent() {
  const { customers_presenter } = usePage<{ customers_presenter: CustomerPageProps }>().props;

  return <CustomersPage {...customers_presenter} />;
}

function Index() {
  return (
    <Deferred data={["customers_presenter"]} fallback={<CustomersContentLoading />}>
      <CustomersContent />
    </Deferred>
  );
}

export default Index;
