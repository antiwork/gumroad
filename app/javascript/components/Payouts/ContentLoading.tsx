import React from "react";

import { Skeleton } from "$app/components/Skeleton";

export const PayoutsContentLoading = () => (
  <div className="space-y-8 p-4 md:p-8">
    <Skeleton className="h-24 w-full" />
    <Skeleton className="h-32 w-full" />
    <Skeleton className="h-32 w-full" />
  </div>
);
