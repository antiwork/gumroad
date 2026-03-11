import React from "react";

import { Skeleton } from "$app/components/Skeleton";
import { PageHeader } from "$app/components/ui/PageHeader";

export const CustomersContentLoading = () => (
  <>
    <PageHeader title="Sales" />
    <div className="space-y-4 p-4 md:p-8">
      <div className="flex gap-4">
        <Skeleton className="h-10 w-48" />
        <Skeleton className="h-10 w-32" />
      </div>
      <Skeleton className="h-12 w-full" />
      <Skeleton className="h-12 w-full" />
      <Skeleton className="h-12 w-full" />
      <Skeleton className="h-12 w-full" />
      <Skeleton className="h-12 w-full" />
    </div>
  </>
);
