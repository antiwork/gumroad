import { usePage } from "@inertiajs/react";
import React from "react";

import { default as ReviewsPage, ReviewsPageProps } from "$app/components/ReviewsPage";

function Reviews() {
  const { reviews, purchases, following_wishlists_enabled } = usePage<ReviewsPageProps>().props;

  return (
    <ReviewsPage reviews={reviews} purchases={purchases} following_wishlists_enabled={following_wishlists_enabled} />
  );
}

export default Reviews;
