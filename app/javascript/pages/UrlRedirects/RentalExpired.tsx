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

function RentalExpired() {
  const props = cast<Props>(usePage().props);
  const productName = props.purchase?.product_name ?? "This product";

  return (
    <UnavailablePage {...props} product_name={productName} title_suffix="Your rental has expired">
      <h2>Your rental has expired</h2>
      <p>Rentals expire 30 days after purchase or 72 hours after you've begun watching it.</p>
    </UnavailablePage>
  );
}

RentalExpired.loggedInUserLayout = true;
export default RentalExpired;
