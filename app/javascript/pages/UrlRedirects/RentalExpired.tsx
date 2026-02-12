import * as React from "react";

import { UnavailablePageLayout, useUnavailablePageProps, withStandaloneLayout } from "./UnavailablePageLayout";

function RentalExpiredPage() {
  const pageProps = useUnavailablePageProps();

  return (
    <UnavailablePageLayout pageProps={pageProps}>
      <h2>Your rental has expired</h2>
      <p>Rentals expire 30 days after purchase or 72 hours after you've begun watching it.</p>
    </UnavailablePageLayout>
  );
}

RentalExpiredPage.layout = withStandaloneLayout;

export default RentalExpiredPage;
