import { usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { LayoutProps } from "$app/components/server-components/DownloadPage/Layout";

import { UnavailablePage } from "./components/UnavailablePage";

type Props = LayoutProps & {
  purchase: LayoutProps["purchase"] & {
    product_name: string;
  } | null;
};

function Expired() {
  const props = cast<Props>(usePage().props);
  const productName = props.purchase?.product_name ?? "This product";

  return (
    <UnavailablePage {...props} product_name={productName} title_suffix="Access expired">
      <h2>Access expired</h2>
      <p>It looks like your access to this product has expired. Please contact the creator for further assistance.</p>
    </UnavailablePage>
  );
}

Expired.loggedInUserLayout = true;
export default Expired;
