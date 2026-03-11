import React from "react";

import { Skeleton } from "$app/components/Skeleton";

export const DashboardContentLoading = () => (
  <>
    <div className="p-4 md:p-8">
      <Skeleton className="mb-4 h-8 w-32" />
      <div className="space-y-2">
        <Skeleton className="h-12 w-full" />
        <Skeleton className="h-12 w-full" />
        <Skeleton className="h-12 w-full" />
      </div>
    </div>
    <div className="grid gap-4 p-4 md:p-8">
      <Skeleton className="h-8 w-24" />
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <Skeleton className="h-24 w-full" />
        <Skeleton className="h-24 w-full" />
        <Skeleton className="h-24 w-full" />
        <Skeleton className="h-24 w-full" />
      </div>
      <div className="space-y-3">
        <Skeleton className="h-10 w-full" />
        <Skeleton className="h-10 w-full" />
        <Skeleton className="h-10 w-full" />
      </div>
    </div>
  </>
);
