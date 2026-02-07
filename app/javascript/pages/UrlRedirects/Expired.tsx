import * as React from "react";

import { UnavailablePageLayout, useUnavailablePageProps, withStandaloneLayout } from "./UnavailablePageLayout";

function ExpiredPage() {
  const pageProps = useUnavailablePageProps();

  return (
    <UnavailablePageLayout pageProps={pageProps}>
      <h2>Access expired</h2>
      <p>It looks like your access to this product has expired. Please contact the creator for further assistance.</p>
    </UnavailablePageLayout>
  );
}

ExpiredPage.layout = withStandaloneLayout;

export default ExpiredPage;
