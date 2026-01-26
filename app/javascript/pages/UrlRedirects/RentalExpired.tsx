import { usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { Layout, LayoutProps } from "$app/components/server-components/DownloadPage/Layout";
import { Placeholder, PlaceholderImage } from "$app/components/ui/Placeholder";

import placeholderImage from "$assets/images/placeholders/comic-stars.png";

type Props = LayoutProps;

function RentalExpired() {
  const props = cast<Props>(usePage().props);

  return (
    <Layout {...props}>
      <Placeholder>
        <PlaceholderImage src={placeholderImage} />
        <h2>Your rental has expired</h2>
        <p>Rentals expire 30 days after purchase or 72 hours after you've begun watching it.</p>
      </Placeholder>
    </Layout>
  );
}

RentalExpired.loggedInUserLayout = true;
export default RentalExpired;
