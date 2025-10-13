import * as React from "react";

import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";

import { type AnalyticsTotal } from "$app/components/Analytics";
import { Icon } from "$app/components/Icons";
import { Stats } from "$app/components/Stats";

export const SalesQuickStats = ({ total }: { total: AnalyticsTotal | undefined }) => (
  <div className="stats-grid">
    <Stats
      title={
        <>
          <Icon name="circle-fill" className="text-foreground" />
          Sales
        </>
      }
      value={total?.sales.toLocaleString() ?? ""}
    />
    <Stats
      title={
        <>
          <Icon name="circle-fill" className="text-muted-foreground" />
          Views
        </>
      }
      value={total?.views.toLocaleString() ?? ""}
    />
    <Stats
      title={
        <>
          <Icon name="circle-fill" className="text-accent" />
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
