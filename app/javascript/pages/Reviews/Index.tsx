import { usePage } from "@inertiajs/react";
import React from "react";
import { cast } from "ts-safe-cast";

import ReviewsPage from "$app/components/Reviews/ReviewsPage";

type Props = React.ComponentProps<typeof ReviewsPage>;

export default function ReviewsIndex() {
  const props = cast<Props>(usePage().props);

  return <ReviewsPage {...props} />;
}
