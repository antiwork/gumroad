import { usePage } from "@inertiajs/react";
import * as React from "react";

import { CheckoutPageContent, type Props as CheckoutProps } from "$app/components/Checkout/CheckoutPageContent";

function CheckoutPage() {
  const props = usePage<CheckoutProps>().props;

  return <CheckoutPageContent {...props} />;
}

CheckoutPage.loggedInUserLayout = true;
export default CheckoutPage;
