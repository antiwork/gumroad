import * as React from "react";

import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";

import { type AnalyticsTotal } from "$app/components/Analytics";
import { Stats } from "$app/components/Stats";
import { Circle } from "@boxicons/react";

export const SalesQuickStats = ({ total }: { total: AnalyticsTotal | undefined }) => (
  <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
    <Stats
      title={
        <>
          <Circle pack="filled" className="text-foreground" />
          Sales
        </>
      }
      value={total?.sales.toLocaleString() ?? ""}
    />
    <Stats
      title={
        <>
          <Circle pack="filled" className="text-active-bg" />
          Views
        </>
      }
      value={total?.views.toLocaleString() ?? ""}
    />
    <Stats
      title={
        <>
          <Circle pack="filled" className="text-accent" />
          Total
        </>
      }
      value={
        total
          ? formatPriceCentsWithCurrencySymbol("usd", total.totals, {
              symbolFormat: "short",
              noCentsIfWhole: true,
            })
          : ""
      }
    />
  </div>
);
