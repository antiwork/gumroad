import { usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { StandaloneLayout } from "$app/inertia/layout";

import { Layout, LayoutProps } from "$app/components/server-components/DownloadPage/Layout";
import { Placeholder, PlaceholderImage } from "$app/components/ui/Placeholder";

import placeholderImage from "$assets/images/placeholders/comic-stars.png";

export type UnavailablePageProps = LayoutProps;

export const useUnavailablePageProps = () => cast<UnavailablePageProps>(usePage().props);

const fullHeightPlaceholderClassName = "flex-1 content-center";

export const UnavailablePageLayout = ({
  pageProps,
  children,
}: {
  pageProps: UnavailablePageProps;
  children: React.ReactNode;
}) => (
  <Layout {...pageProps}>
    <Placeholder className={fullHeightPlaceholderClassName}>
      <PlaceholderImage src={placeholderImage} />
      {children}
    </Placeholder>
  </Layout>
);

export const withStandaloneLayout = (page: React.ReactNode) => <StandaloneLayout>{page}</StandaloneLayout>;
