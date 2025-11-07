import { lightFormat } from "date-fns";
import * as React from "react";

import { fetchChurnSummary, fetchChurnData, ChurnSummaryData, ChurnDataResponse } from "$app/data/churn";
import { AbortError } from "$app/utils/request";

import { AnalyticsLayout } from "$app/components/Analytics/AnalyticsLayout";
import { ChurnChart, ChurnDailyData } from "$app/components/Analytics/Churn/ChurnChart";
import { ChurnQuickStats } from "$app/components/Analytics/Churn/ChurnQuickStats";
import { useAnalyticsDateRange } from "$app/components/Analytics/useAnalyticsDateRange";
import { DateRangePicker } from "$app/components/DateRangePicker";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { showAlert } from "$app/components/server-components/Alert";
import Placeholder from "$app/components/ui/Placeholder";

import placeholder from "$assets/images/placeholders/sales.png";

export type Product = {
  name: string;
  id: string;
  alive: boolean;
  unique_permalink: string;
};

export type ChurnProps = {
  products: Product[];
  has_subscription_products: boolean;
};

const Churn = ({ products: initialProducts, has_subscription_products }: ChurnProps) => {
  const [aggregateBy, setAggregateBy] = React.useState<"daily" | "monthly">("daily");
  const dateRange = useAnalyticsDateRange();
  const [summary, setSummary] = React.useState<ChurnSummaryData | null>(null);
  const [dailyData, setDailyData] = React.useState<ChurnDataResponse | null>(null);
  const startTime = lightFormat(dateRange.from, "yyyy-MM-dd");
  const endTime = lightFormat(dateRange.to, "yyyy-MM-dd");

  const hasContent = has_subscription_products && initialProducts.length > 0;

  const activeRequest = React.useRef<AbortController | null>(null);
  React.useEffect(() => {
    const loadData = async () => {
      if (!hasContent) return;

      try {
        if (activeRequest.current) activeRequest.current.abort();
        setSummary(null);
        setDailyData(null);

        // Fetch both summary and daily data in parallel
        const summaryRequest = fetchChurnSummary({ startTime, endTime });
        const dataRequest = fetchChurnData({ startTime, endTime });
        activeRequest.current = summaryRequest.abort;

        const [summaryData, churnData] = await Promise.all([
          summaryRequest.response,
          dataRequest.response
        ]);

        setSummary(summaryData);
        setDailyData(churnData);
        activeRequest.current = null;
      } catch (e) {
        if (e instanceof AbortError) return;
        showAlert("Sorry, something went wrong. Please try again.", "error");
      }
    };
    void loadData();
  }, [startTime, endTime, hasContent]);

  // Transform backend data into chart format
  const chartData = React.useMemo((): ChurnDailyData[] => {
    if (!dailyData || !initialProducts.length) return [];

    const dataPoints: ChurnDailyData[] = [];

    // The backend returns data keyed by [product_id, date]
    // We need to aggregate across all products for each date
    const dateMap = new Map<string, {
      churn_rate: number;
      cancelled_count: number;
      revenue_lost_cents: number;
      active_at_start: number;
      new_subscriptions: number;
      count: number;
    }>();

    // Aggregate data by date across all products
    Object.entries(dailyData.by_product_and_date).forEach(([key, value]) => {
      const [_productId, dateStr] = JSON.parse(`[${key}]`);
      const existing = dateMap.get(dateStr);

      if (existing) {
        // Accumulate counts for proper weighted average
        const totalActive = existing.active_at_start + value.active_at_start;
        const totalNew = existing.new_subscriptions + value.new_subscriptions;
        const totalCancelled = existing.cancelled_count + value.cancelled_count;
        const totalDenominator = totalActive + totalNew;

        dateMap.set(dateStr, {
          churn_rate: totalDenominator > 0 ? (totalCancelled / totalDenominator * 100) : 0,
          cancelled_count: totalCancelled,
          revenue_lost_cents: existing.revenue_lost_cents + value.revenue_lost_cents,
          active_at_start: totalActive,
          new_subscriptions: totalNew,
          count: existing.count + 1
        });
      } else {
        dateMap.set(dateStr, {
          ...value,
          count: 1
        });
      }
    });

    // Convert to array format for chart
    dateMap.forEach((value, dateStr) => {
      const date = new Date(dateStr);
      const month = lightFormat(date, "MMMM");
      const monthIndex = date.getMonth();

      dataPoints.push({
        date: dateStr,
        month,
        monthIndex,
        churn_rate: value.churn_rate,
        cancelled_count: value.cancelled_count,
        revenue_lost_cents: value.revenue_lost_cents,
        active_at_start: value.active_at_start,
        new_subscriptions: value.new_subscriptions,
      });
    });

    // Sort by date
    return dataPoints.sort((a, b) => a.date.localeCompare(b.date));
  }, [dailyData, initialProducts]);

  return (
    <AnalyticsLayout
      selectedTab="churn"
      actions={
        hasContent ? (
          <>
            <select
              aria-label="Aggregate by"
              onChange={(e) => setAggregateBy(e.target.value === "daily" ? "daily" : "monthly")}
              className="w-auto"
            >
              <option value="daily">Daily</option>
              <option value="monthly">Monthly</option>
            </select>
            <DateRangePicker {...dateRange} />
          </>
        ) : null
      }
    >
      {hasContent ? (
        <div className="space-y-8 p-4 md:p-8">
          <ChurnQuickStats summary={summary ?? undefined} />
          {summary && dailyData ? (
            <ChurnChart
              data={chartData}
              startDate={startTime}
              endDate={endTime}
              aggregateBy={aggregateBy}
            />
          ) : (
            <div className="input">
              <LoadingSpinner />
              Loading churn data...
            </div>
          )}
        </div>
      ) : (
        <div className="p-4 md:p-8">
          <Placeholder>
            <figure>
              <img src={placeholder} alt="No subscription products" />
            </figure>
            <h2>No subscription products found</h2>
            <p>
              Churn analytics are only available for creators with subscription or membership products. Once you create
              a subscription product, you'll see churn metrics here.
            </p>
            <a href="/help" target="_blank" rel="noreferrer">
              Learn more about subscriptions
            </a>
          </Placeholder>
        </div>
      )}
    </AnalyticsLayout>
  );
};

export default Churn;
