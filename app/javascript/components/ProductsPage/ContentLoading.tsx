import React from "react";

import { Skeleton } from "$app/components/Skeleton";

export const ProductsContentLoading = () => (
  <section className="space-y-4 p-4 md:p-8">
    <Skeleton className="h-12 w-full" />
    <Skeleton className="h-12 w-full" />
    <Skeleton className="h-12 w-full" />
    <Skeleton className="h-12 w-full" />
    <Skeleton className="h-12 w-full" />
  </section>
);
