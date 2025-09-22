import { usePage } from "@inertiajs/react";
import React from "react";

import { default as CheckoutPage, CheckoutPageProps } from "$app/components/server-components/CheckoutPage";

function Checkout() {
  const { checkout_page_props } = usePage<{ checkout_page_props: CheckoutPageProps }>().props;

  return <CheckoutPage {...checkout_page_props} />;
}

export default Checkout;
