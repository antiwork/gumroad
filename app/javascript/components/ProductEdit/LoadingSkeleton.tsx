import * as React from "react";

import { Skeleton } from "$app/components/Skeleton";

// What the product editor shows while its code and data are still arriving.
//
// The shape deliberately matches the real editor — a header with the product title and its action
// buttons, the four tabs, the form on the left, the product preview on the right — so the page
// feels like it is filling in rather than replacing itself. Before this, a click on a product
// showed the previous page until everything was ready, which is what made sellers think their
// click had done nothing (gumroad-private#1469).
export const ProductEditLoadingSkeleton = ({ title }: { title?: string | null }) => (
  <div aria-busy="true" aria-live="polite">
    <span className="sr-only">Loading product…</span>
    <header className="flex flex-col gap-4 border-b border-border p-4 md:p-8">
      <div className="flex items-center justify-between gap-2 sm:min-h-8">
        {/* The product name is already known from the row that was clicked, so show the real title
            instead of a grey bar — it confirms which product is opening. */}
        {title ? (
          <h1 className="line-clamp-2 hidden! text-2xl sm:block!">{title}</h1>
        ) : (
          <Skeleton className="hidden! h-8 w-64 sm:block!" />
        )}
        <div className="grid flex-1 grid-cols-2 gap-2 sm:flex sm:flex-none sm:justify-end md:-my-2">
          <Skeleton className="h-10 w-full sm:w-28" />
          <Skeleton className="h-10 w-full sm:w-36" />
        </div>
      </div>
      <div className="flex gap-2">
        {["Product", "Content", "Receipt", "Share"].map((tab) => (
          <Skeleton key={tab} className="h-8 w-20" />
        ))}
      </div>
    </header>

    <div className="lg:grid lg:grid-cols-[1fr_30vw]">
      <div className="flex flex-col gap-6 p-4 md:p-8">
        {/* Name, pricing, description: the three sections at the top of the Product tab. */}
        <div className="flex flex-col gap-2">
          <Skeleton className="h-4 w-16" />
          <Skeleton className="h-10 w-full" />
        </div>
        <div className="flex flex-col gap-2">
          <Skeleton className="h-4 w-12" />
          <Skeleton className="h-10 w-40" />
        </div>
        <div className="flex flex-col gap-2">
          <Skeleton className="h-4 w-24" />
          <Skeleton className="h-40 w-full" />
        </div>
      </div>

      <div className="hidden border-l border-border p-4 lg:block">
        <Skeleton className="h-8 w-full" />
        <Skeleton className="mt-4 aspect-square w-full" />
      </div>
    </div>
  </div>
);
