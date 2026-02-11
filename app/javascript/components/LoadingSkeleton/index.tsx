import React from "react";

import { Skeleton } from "$app/components/Skeleton";
import { PageHeader } from "$app/components/ui/PageHeader";

function LoadingSkeleton() {
  return (
    <div className="flex flex-1 flex-col overflow-y-auto">
      <PageHeader className="border-none" title={<Skeleton className="h-12 w-56" />} />
      <section className="flex flex-1 flex-col gap-4 p-4 md:p-8">
        <Skeleton className="w-full flex-1" />
        <Skeleton className="w-full flex-1" />
        <Skeleton className="w-full flex-1" />
        <Skeleton className="w-full flex-1" />
      </section>
    </div>
  );
}

export default LoadingSkeleton;
