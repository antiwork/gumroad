import { usePage } from "@inertiajs/react";
import * as React from "react";
import typia, { TypeGuardError } from "typia";

import { PoweredByFooter } from "$app/components/PoweredByFooter";
import { Layout, Props } from "$app/components/Product/Layout";

function ProductShowPage() {
  const rawProps = usePage().props;
  let props: Props;
  try {
    props = typia.assert<Props>(rawProps);
  } catch (e) {
    if (e instanceof TypeGuardError) {
      console.error("[ProductShowPage] typia.assert<Props> failed", {
        path: e.path,
        expected: e.expected,
        value: e.value,
      });
    }
    throw e;
  }

  return (
    <>
      <Layout {...props} />
      <PoweredByFooter />
    </>
  );
}

ProductShowPage.loggedInUserLayout = true;
export default ProductShowPage;
