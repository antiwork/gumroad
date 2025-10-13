import * as React from "react";

import { type ChurnMetrics } from "$app/data/churn";
import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";

import { Stats } from "$app/components/Stats";

export const ChurnQuickStats = ({ metrics }: { metrics: ChurnMetrics | undefined }) => {
  const churnRate = metrics ? metrics.customer_churn_rate : 0;
  const lastPeriodChurnRate = metrics ? metrics.last_period_churn_rate : 0;
  const revenueLost = metrics ? metrics.churned_mrr_cents : 0;
  const churnedUsers = metrics ? metrics.churned_subscribers : 0;

  return (
    <div className="stats-grid">
      <Stats title={<>Churn rate</>} value={`${churnRate.toFixed(1)}%`} />
      <Stats title={<>Last period churn rate</>} value={`${lastPeriodChurnRate.toFixed(1)}%`} />
      <Stats
        title={<>Revenue lost</>}
        value={
          metrics
            ? formatPriceCentsWithCurrencySymbol("usd", revenueLost, {
                symbolFormat: "short",
                noCentsIfWhole: true,
              })
            : ""
        }
      />
      <Stats title={<>Churned users</>} value={churnedUsers.toString()} />
    </div>
  );
};
