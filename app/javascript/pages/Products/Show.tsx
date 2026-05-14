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
      const detail = `TYPIA_ASSERT_FAILED ProductShowPage<Props>\npath: ${e.path ?? "(none)"}\nexpected: ${e.expected ?? "(none)"}\nvalue: ${JSON.stringify(e.value)}`;
      console.error(detail);
      return (
        <pre
          data-testid="typia-error"
          style={{ padding: 16, fontSize: 12, whiteSpace: "pre-wrap", wordBreak: "break-all", background: "#fff" }}
        >
          {detail}
        </pre>
      );
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
