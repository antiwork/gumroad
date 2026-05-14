import { usePage } from "@inertiajs/react";
import * as React from "react";
import typia from "typia";

import { PoweredByFooter } from "$app/components/PoweredByFooter";
import { Layout, Props } from "$app/components/Product/Layout";

function ProductShowPage() {
  const props = typia.assert<Props>(usePage().props);

  return (
    <>
      <Layout {...props} />
      <PoweredByFooter />
    </>
  );
}

ProductShowPage.loggedInUserLayout = true;
export default ProductShowPage;
