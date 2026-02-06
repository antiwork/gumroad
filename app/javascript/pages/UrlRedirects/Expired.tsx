import { usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { StandaloneLayout } from "$app/inertia/layout";

import { Placeholder, PlaceholderImage } from "$app/components/ui/Placeholder";

import { UnavailablePageLayout, type UnavailablePageProps } from "./UnavailablePageLayout";

import placeholderImage from "$assets/images/placeholders/comic-stars.png";

type Props = UnavailablePageProps;

const Expired = () => {
  const props = cast<Props>(usePage().props);

  return (
    <UnavailablePageLayout {...props} contentUnavailabilityReasonCode="access_expired">
      <Placeholder className="flex-1 content-center">
        <PlaceholderImage src={placeholderImage} />
        <h2>Access expired</h2>
        <p>It looks like your access to this product has expired. Please contact the creator for further assistance.</p>
      </Placeholder>
    </UnavailablePageLayout>
  );
};

Expired.layout = (page: React.ReactNode) => <StandaloneLayout>{page}</StandaloneLayout>;

export default Expired;
