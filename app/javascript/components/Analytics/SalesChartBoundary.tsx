import * as React from "react";

import { Button } from "$app/components/Button";
import { FallbackOnError } from "$app/components/FallbackOnError";

// Keep chart chunk failures inside the chart box; the rest of Analytics remains useful.
// Reloading is the recovery because React.lazy caches a rejected import for this document.
const SalesChartLoadFailed = () => (
  <div role="alert" className="flex flex-col items-center gap-3 p-8 text-center">
    <p>We couldn&apos;t load the sales chart. Your sales data is unaffected.</p>
    <Button onClick={() => location.reload()}>Reload</Button>
  </div>
);

export const SalesChartBoundary = ({ children }: { children: React.ReactNode }) => (
  <FallbackOnError fallback={<SalesChartLoadFailed />}>{children}</FallbackOnError>
);
