import * as React from "react";

import { Skeleton } from "$app/components/Skeleton";

// The chart occupies a fixed-height box in the real page, so the skeleton claims the same height
// and nothing below it moves when the chart arrives.
export const SalesChartSkeleton = () => (
  <section aria-busy="true" aria-live="polite">
    <span className="sr-only">Loading sales chart…</span>
    <div className="rounded-md border border-border p-4">
      <div className="flex items-end gap-2" style={{ height: "16rem" }}>
        {/* Varying bar heights read as a chart rather than a grey block. */}
        {[40, 65, 30, 80, 55, 70, 45, 90, 60, 35, 75, 50].map((height, index) => (
          <Skeleton key={index} className="flex-1" style={{ height: `${height}%` }} />
        ))}
      </div>
      <div className="mt-4 flex justify-between">
        <Skeleton className="h-4 w-20" />
        <Skeleton className="h-4 w-20" />
      </div>
    </div>
  </section>
);

// One header row plus five body rows: enough to look like the table that replaces it without
// promising a row count we don't know yet.
export const AnalyticsTableSkeleton = ({ label, columns }: { label: string; columns: number }) => (
  <section aria-busy="true" aria-live="polite">
    <span className="sr-only">{`Loading ${label}…`}</span>
    <div className="rounded-md border border-border">
      <div className="flex gap-4 border-b border-border p-4">
        {Array.from({ length: columns }, (_, index) => (
          <Skeleton key={index} className="h-4 flex-1" />
        ))}
      </div>
      {Array.from({ length: 5 }, (_, row) => (
        <div key={row} className="flex gap-4 border-b border-border p-4 last:border-b-0">
          {Array.from({ length: columns }, (_, index) => (
            <Skeleton key={index} className="h-4 flex-1" />
          ))}
        </div>
      ))}
    </div>
  </section>
);
