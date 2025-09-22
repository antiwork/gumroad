import { usePage } from "@inertiajs/react";
import React from "react";

import { default as FormPage, FormPageProps } from "$app/components/server-components/CheckoutDashboard/FormPage";

function Form() {
  const { form_page_props } = usePage<{ form_page_props: FormPageProps }>().props;

  return <FormPage {...form_page_props} />;
}

export default Form;
