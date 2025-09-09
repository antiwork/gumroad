import React from "react";

import { Skeleton } from "$app/components/Skeleton";

function LoadingSkeleton() {
  return (
    <main>
      <header className="border-none">
        <h1>
          <Skeleton className="h-12 w-56" />
        </h1>
      </header>
      <section className="h-full space-y-4">
        <Skeleton className="h-1/5 w-full" />
        <Skeleton className="h-1/5 w-full" />
        <Skeleton className="h-1/5 w-full" />
        <Skeleton className="h-1/5 w-full" />
      </section>
    </main>
  );
}

export default LoadingSkeleton;
