import React, { Suspense, lazy, useEffect, useState } from "react";

import {
  ReviewVideoRecorderContainer,
  ReviewVideoRecorderProps,
} from "$app/components/ReviewForm/ReviewVideoRecorderCommon";

const ReviewVideoRecorderClientOnly = lazy(() => import("$app/components/ReviewForm/ReviewVideoRecorderClientOnly"));

// This intentionally does not use a loading spinner, as it loads fast enough
// most of the time and the spinner would make the UI feel jumpy.
const ReviewVideoRecorderFallback = () => <ReviewVideoRecorderContainer />;

export const ReviewVideoRecorder = (props: ReviewVideoRecorderProps) => {
  const [key, setKey] = useState(0);
  const [clientRenderingStarted, setClientRenderingStarted] = useState(false);

  // Force remount to reacquire the stream, instead of trying to manage the
  // stream state manually.
  const reacquireStream = () => {
    setKey((key) => key + 1);
  };

  useEffect(() => {
    setClientRenderingStarted(true);
  }, []);

  // Defer loading and rendering of ReviewVideoRecorderClientOnly to avoid SSR
  // errors of "Blob is not defined".
  return clientRenderingStarted ? (
    <Suspense fallback={<ReviewVideoRecorderFallback />}>
      <ReviewVideoRecorderClientOnly {...props} key={key} reacquireStream={reacquireStream} />
    </Suspense>
  ) : (
    <ReviewVideoRecorderFallback />
  );
};
