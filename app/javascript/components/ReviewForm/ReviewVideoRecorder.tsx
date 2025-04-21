import React, { Suspense, lazy, useState } from "react";

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

  // Force remount to reacquire the stream, instead of trying to manage the
  // stream state manually.
  const reacquireStream = () => {
    setKey((key) => key + 1);
  };

  return (
    <Suspense fallback={<ReviewVideoRecorderFallback />}>
      <ReviewVideoRecorderClientOnly {...props} key={key} reacquireStream={reacquireStream} />
    </Suspense>
  );
};
