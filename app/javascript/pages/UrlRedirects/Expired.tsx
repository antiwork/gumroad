import { usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { Layout, LayoutProps } from "$app/components/server-components/DownloadPage/Layout";
import { Placeholder, PlaceholderImage } from "$app/components/ui/Placeholder";

import placeholderImage from "$assets/images/placeholders/comic-stars.png";

type Props = LayoutProps;

function Expired() {
  const props = cast<Props>(usePage().props);

  return (
    <Layout {...props}>
      <Placeholder>
        <PlaceholderImage src={placeholderImage} />
        <h2>Access expired</h2>
        <p>It looks like your access to this product has expired. Please contact the creator for further assistance.</p>
      </Placeholder>
    </Layout>
  );
}

Expired.loggedInUserLayout = true;
export default Expired;
