import React, { Suspense, lazy } from "react";

import { ReviewVideoRecorderContainer, ReviewVideoRecorderProps } from "$app/components/ReviewForm/VideoReviewCommon";

const ReviewVideoRecorderClientOnly = lazy(() => import("$app/components/ReviewForm/ReviewVideoRecorderClientOnly"));

// I initially tried to use a loading spinner here, but it loaded fast enough
// most of the time and the spinner ended up making the UI feel jumpy.
const ReviewVideoRecorderFallback = () => <ReviewVideoRecorderContainer />;

export const ReviewVideoRecorder = (props: ReviewVideoRecorderProps) => (
  <Suspense fallback={<ReviewVideoRecorderFallback />}>
    <ReviewVideoRecorderClientOnly {...props} />
  </Suspense>
);
