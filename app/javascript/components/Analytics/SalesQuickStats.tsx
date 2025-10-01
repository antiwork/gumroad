import * as React from "react";

import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";

import { Icon } from "$app/components/Icons";
import { AnalyticsTotal } from "$app/components/server-components/AnalyticsPage";
import { Stats } from "$app/components/Stats";

export const SalesQuickStats = ({ total }: { total: AnalyticsTotal | undefined }) => (
  <div className="grid gap-4 sm:grid-cols-1 md:grid-cols-2 lg:grid-cols-3 override">
    <Stats
      title={
        <>
          <Icon name="circle-fill" style={{ color: "rgb(var(--color))" }} />
          Sales
        </>
      }
      value={total?.sales.toLocaleString() ?? ""}
    />
    <Stats
      title={
        <>
          <Icon name="circle-fill" style={{ color: "rgb(var(--color) / var(--gray-1))" }} />
          Views
        </>
      }
      value={total?.views.toLocaleString() ?? ""}
    />
    <Stats
      title={
        <>
          <Icon name="circle-fill" style={{ color: "rgb(var(--accent))" }} />
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
