import { lightFormat } from "date-fns";
import * as React from "react";

import { fetchChurnData, type ChurnData } from "$app/data/churn";
import { AbortError } from "$app/utils/request";

import { AnalyticsLayout } from "$app/components/Analytics/AnalyticsLayout";
import { useAnalyticsDateRange } from "$app/components/Analytics/useAnalyticsDateRange";
import { ChurnChart } from "$app/components/Churn/ChurnChart";
import { ChurnQuickStats } from "$app/components/Churn/ChurnQuickStats";
import { DateRangePicker } from "$app/components/DateRangePicker";
import { Progress } from "$app/components/Progress";
import { showAlert } from "$app/components/server-components/Alert";

import placeholder from "$assets/images/placeholders/sales.png";

export type ChurnProps = {
  has_subscription_products: boolean;
};

const Churn = ({ has_subscription_products }: ChurnProps) => {
  const dateRange = useAnalyticsDateRange();
  const [data, setData] = React.useState<ChurnData | null>(null);

  const startTime = lightFormat(dateRange.from, "yyyy-MM-dd");
  const endTime = lightFormat(dateRange.to, "yyyy-MM-dd");

  const hasContent = has_subscription_products;

  const activeRequest = React.useRef<AbortController | null>(null);

  React.useEffect(() => {
    const loadData = async () => {
      if (!hasContent) return;

      try {
        if (activeRequest.current) {
          activeRequest.current.abort();
        }

        setData(null);

        const request = fetchChurnData({ startTime, endTime });
        activeRequest.current = request.abort;

        const result = await request.response;
        setData(result);
        activeRequest.current = null;
      } catch (e) {
        if (e instanceof AbortError) return;
        showAlert("Sorry, something went wrong. Please try again.", "error");
      }
    };

    void loadData();
  }, [startTime, endTime, hasContent]);

  return (
    <AnalyticsLayout selectedTab="churn" actions={hasContent ? <DateRangePicker {...dateRange} /> : null}>
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
            <a href="/help/article/172-memberships" target="_blank" rel="noreferrer">
              Learn more about memberships
            </a>
          </div>
        </div>
      )}
    </AnalyticsLayout>
  );
};

export default Churn;
