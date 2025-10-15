import { router } from "@inertiajs/react";
import { lightFormat } from "date-fns";
import * as React from "react";

export type ChurnData = {
  start_date: string;
  end_date: string;
  metrics: {
    customer_churn_rate: number;
    last_period_churn_rate: number;
    churned_subscribers: number;
    churned_mrr_cents: number;
  };
  daily_data: {
    date: string;
    customer_churn_rate: number;
    churned_subscribers: number;
    churned_mrr_cents: number;
  }[];
};

import { AnalyticsLayout } from "$app/components/Analytics/AnalyticsLayout";
import { useAnalyticsDateRange } from "$app/components/Analytics/useAnalyticsDateRange";
import { ChurnChart } from "$app/components/Churn/ChurnChart";
import { ChurnDateRangePicker } from "$app/components/Churn/ChurnDateRangePicker";
import ChurnQuickStats from "$app/components/Churn/ChurnQuickStats";
import { Progress } from "$app/components/Progress";

import placeholder from "$assets/images/placeholders/sales.png";

export type ChurnProps = {
  has_subscription_products: boolean;
  churn_data: ChurnData | null;
};

const isChurnData = (data: unknown): data is ChurnData =>
  typeof data === "object" &&
  data !== null &&
  "daily_data" in data &&
  "metrics" in data &&
  "start_date" in data &&
  "end_date" in data;

const Churn = ({ has_subscription_products, churn_data }: ChurnProps) => {
  const dateRange = useAnalyticsDateRange();
  const [data, setData] = React.useState<ChurnData | null>(churn_data || null);

  const hasContent = has_subscription_products;

  // Handle date range changes using Inertia partial reload
  React.useEffect(() => {
    if (!hasContent) return;

    const fromDate = lightFormat(dateRange.from, "yyyy-MM-dd");
    const toDate = lightFormat(dateRange.to, "yyyy-MM-dd");

    router.reload({
      only: ["churn_data"],
      data: {
        from: fromDate,
        to: toDate,
      },
      onSuccess: (page) => {
        const churnData = page.props.churn_data;
        if (isChurnData(churnData)) {
          setData(churnData);
        }
      },
    });
  }, [dateRange.from, dateRange.to, hasContent]);

  return (
    <AnalyticsLayout selectedTab="churn" actions={hasContent ? <ChurnDateRangePicker {...dateRange} /> : null}>
      {hasContent ? (
        <div className="space-y-8 p-4 md:p-8">
          <ChurnQuickStats metrics={data?.metrics} />
          {data ? (
            <ChurnChart data={data.daily_data} />
          ) : (
            <div className="input">
              <Progress width="1em" />
              Loading charts...
            </div>
          )}
        </div>
      ) : (
        <div className="p-4 md:p-8">
          <div className="placeholder">
            <figure>
              <img src={placeholder} />
            </figure>
            <h2>No subscription products yet</h2>
            <p>
              Churn analytics are available for creators with active subscription products. Create a membership or
              subscription product to start tracking subscriber retention.
            </p>
            <a href={Routes.help_center_article_path("172-memberships")} target="_blank" rel="noreferrer">
              Learn more about memberships
            </a>
          </div>
        </div>
      )}
    </AnalyticsLayout>
  );
};

export default Churn;
