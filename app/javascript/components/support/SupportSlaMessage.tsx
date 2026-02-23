import * as React from "react";

export function SupportSlaMessage({ children }: { children?: React.ReactNode }): React.ReactNode {
  return (
    <>
      You'll most likely hear back within an hour — 97.7% of people do. We guarantee a response within 24 hours.
      {children}
    </>
  );
}
