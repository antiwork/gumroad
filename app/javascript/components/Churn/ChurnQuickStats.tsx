import * as React from "react";

import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";

import { Stats } from "$app/components/Stats";

export type ChurnSummary = {
  churnRate: number;
  churnedCustomers: number;
  revenueLostCents: number;
  previousPeriodChurnRate: number | null;
};

const ChurnQuickStats = ({ summary }: { summary: ChurnSummary }) => (
  <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
    <Stats title={<>Churn rate</>} value={`${summary.churnRate.toFixed(2)}%`} />
    <Stats
      title={<>Last period churn rate</>}
      value={summary.previousPeriodChurnRate === null ? "—" : `${summary.previousPeriodChurnRate.toFixed(2)}%`}
    />
    <Stats title={<>Churned users</>} value={summary.churnedCustomers.toLocaleString()} />
    <Stats
      title={<>Revenue lost</>}
      value={formatPriceCentsWithCurrencySymbol("usd", summary.revenueLostCents, {
        symbolFormat: "short",
        noCentsIfWhole: true,
      })}
    />
  </div>
);

export default ChurnQuickStats;
