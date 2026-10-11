import { usePage } from "@inertiajs/react";
import * as React from "react";

import { cast } from "$app/utils/cast";

import { PoweredByFooter } from "$app/components/PoweredByFooter";
import { Layout, Props } from "$app/components/Product/Layout";

function ProductShowPage() {
  const props = cast<Props>(usePage().props);

  return (
    <>
      <Layout {...props} />
      <PoweredByFooter currencySelector shownCurrency={props.product.buyer_currency_display?.buyer_currency_shown} />
    </>
  );
}

ProductShowPage.loggedInUserLayout = true;
export default ProductShowPage;
