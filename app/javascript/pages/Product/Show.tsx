import { usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { PoweredByFooter } from "$app/components/PoweredByFooter";
import { Layout, Props } from "$app/components/Product/Layout";

export default function ProductShowPage() {
  const props = cast<Props>(usePage().props);

  return (
    <>
      <Layout {...props} />
      <PoweredByFooter />
    </>
  );
}
