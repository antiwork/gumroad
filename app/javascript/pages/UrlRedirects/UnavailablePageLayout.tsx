import * as React from "react";

import MetaTags from "$app/layouts/components/MetaTags";

import { Layout, type LayoutProps } from "$app/components/server-components/DownloadPage/Layout";

export type UnavailablePageProps = Omit<LayoutProps, "content_unavailability_reason_code" | "children">;

export const UnavailablePageLayout = ({
  contentUnavailabilityReasonCode,
  children,
  ...layoutProps
}: UnavailablePageProps & {
  contentUnavailabilityReasonCode: LayoutProps["content_unavailability_reason_code"];
  children: React.ReactNode;
}) => (
  <>
    <MetaTags />
    <Layout {...layoutProps} content_unavailability_reason_code={contentUnavailabilityReasonCode}>
      {children}
    </Layout>
  </>
);
