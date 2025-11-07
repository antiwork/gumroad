import * as React from "react";

import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";

import { Icon } from "$app/components/Icons";
import { Stats } from "$app/components/Stats";

export type ChurnSummary = {
  current_period: {
    churn_rate: number;
    churned_users: number;
    revenue_lost_cents: number;
  };
  last_period: {
    churn_rate: number;
  };
};

export const ChurnQuickStats = ({ summary }: { summary: ChurnSummary | undefined }) => {
  const currentChurnRate = summary?.current_period.churn_rate ?? 0;
  const lastChurnRate = summary?.last_period.churn_rate ?? 0;
  const churnedUsers = summary?.current_period.churned_users ?? 0;
  const revenueLost = summary?.current_period.revenue_lost_cents ?? 0;

  return (
    <div className="stats-grid">
      <Stats
        title={
          <>
            <Icon name="circle-fill" className="text-foreground" />
            Churn Rate
          </>
        }
        value={`${currentChurnRate.toFixed(2)}%`}
      />
      <Stats
        title={
          <>
            <Icon name="circle-fill" className="text-active-bg" />
            Last Period Churn Rate
          </>
        }
        value={`${lastChurnRate.toFixed(2)}%`}
      />
      <Stats
        title={
          <>
            <Icon name="circle-fill" className="text-accent" />
            Revenue Lost
          </>
        }
        value={formatPriceCentsWithCurrencySymbol("usd", revenueLost, {
          symbolFormat: "short",
          noCentsIfWhole: true,
        })}
      />
      <Stats
        title={
          <>
            <Icon name="circle-fill" className="text-error" />
            Churned Users
          </>
        }
        value={churnedUsers.toLocaleString()}
      />
    </div>
  );
};
