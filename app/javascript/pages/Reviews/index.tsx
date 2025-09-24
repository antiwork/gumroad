import { usePage } from "@inertiajs/react";
import React from "react";

import { default as ReviewsPage, ReviewsPageProps } from "$app/components/server-components/ReviewsPage";

function Reviews() {
  const { reviews_props } = usePage<{ reviews_props: ReviewsPageProps }>().props;

  return <ReviewsPage {...reviews_props} />;
}

export default Reviews;
