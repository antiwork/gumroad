import { Head } from "@inertiajs/react";
import * as React from "react";

import { Layout, LayoutProps } from "$app/components/server-components/DownloadPage/Layout";
import { Placeholder, PlaceholderImage } from "$app/components/ui/Placeholder";

import placeholderImage from "$assets/images/placeholders/comic-stars.png";

type Props = LayoutProps & {
  product_name: string;
  title_suffix: string;
  children: React.ReactNode;
};

export function UnavailablePage({ product_name, title_suffix, children, ...layoutProps }: Props) {
  return (
    <Layout {...layoutProps}>
      <Head title={`${product_name} - ${title_suffix}`} />
      <Placeholder>
        <PlaceholderImage src={placeholderImage} />
        {children}
      </Placeholder>
    </Layout>
  );
}
