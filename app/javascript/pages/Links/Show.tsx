import React from "react";
import { usePage } from "@inertiajs/react";

import { PoweredByFooter } from "$app/components/PoweredByFooter";
import { Layout, Props } from "$app/components/Product/Layout";

function Show() {
  const props = usePage<{ props: Props }>().props as unknown as Props;

  return (
    <>
      <Layout {...props} />
      <PoweredByFooter />
    </>
  );
}

export default Show;
