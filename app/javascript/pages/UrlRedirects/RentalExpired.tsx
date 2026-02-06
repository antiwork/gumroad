import { usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { StandaloneLayout } from "$app/inertia/layout";

import { Placeholder, PlaceholderImage } from "$app/components/ui/Placeholder";

import { UnavailablePageLayout, type UnavailablePageProps } from "./UnavailablePageLayout";

import placeholderImage from "$assets/images/placeholders/comic-stars.png";

type Props = UnavailablePageProps;

const RentalExpired = () => {
  const props = cast<Props>(usePage().props);

  return (
    <UnavailablePageLayout {...props} contentUnavailabilityReasonCode="rental_expired">
      <Placeholder className="flex-1 content-center">
        <PlaceholderImage src={placeholderImage} />
        <h2>Your rental has expired</h2>
        <p>Rentals expire 30 days after purchase or 72 hours after you've begun watching it.</p>
      </Placeholder>
    </UnavailablePageLayout>
  );
};

RentalExpired.layout = (page: React.ReactNode) => <StandaloneLayout>{page}</StandaloneLayout>;

export default RentalExpired;
