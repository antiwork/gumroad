import React, { Suspense, lazy } from "react";

import { VideoReviewContainer, VideoReviewProps } from "$app/components/ReviewForm/VideoReviewCommon";

const VideoReviewClientOnly = lazy(() => import("$app/components/ReviewForm/VideoReviewClientOnly"));

// I initially tried to use a loading spinner here, but it loaded fast enough
// most of the time and the spinner ended up making the UI feel jumpy.
const VideoReviewFallback = () => <VideoReviewContainer />;

export const VideoReview = ({ formState, videoUrl }: VideoReviewProps) => (
  <Suspense fallback={<VideoReviewFallback />}>
    <VideoReviewClientOnly formState={formState} videoUrl={videoUrl} />
  </Suspense>
);
