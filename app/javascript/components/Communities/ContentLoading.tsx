import React from "react";

import { Skeleton } from "$app/components/Skeleton";

export const CommunitiesContentLoading = () => (
  <div className="p-4 md:p-8">
    <div className="space-y-4">
      <Skeleton className="h-8 w-48" />
      <Skeleton className="h-16 w-full" />
      <Skeleton className="h-16 w-full" />
      <Skeleton className="h-16 w-full" />
    </div>
  </div>
);
