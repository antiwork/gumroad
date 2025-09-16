import React from "react";

import { Skeleton } from "$app/components/Skeleton";
import { PageHeader } from "$app/components/ui/PageHeader";

function LoadingSkeleton() {
  return (
    <div className="flex-1">
      <PageHeader className="border-none" title={<Skeleton className="h-12 w-56" />} />
      <section className="h-full space-y-4 p-4 md:p-8">
        <Skeleton className="h-1/5 w-full" />
        <Skeleton className="h-1/5 w-full" />
        <Skeleton className="h-1/5 w-full" />
        <Skeleton className="h-1/5 w-full" />
      </section>
    </div>
  );
}

export default LoadingSkeleton;
