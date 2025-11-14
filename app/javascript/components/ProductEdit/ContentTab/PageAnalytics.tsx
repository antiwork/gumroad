import * as React from "react";
import { Bar, BarChart, Cell, XAxis, YAxis } from "recharts";
import { cast } from "ts-safe-cast";

import { request } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { Chart, xAxisProps, yAxisProps } from "$app/components/Chart";
import useChartTooltip from "$app/components/Analytics/useChartTooltip";
import { Icon } from "$app/components/Icons";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { WithTooltip } from "$app/components/WithTooltip";

type PageViewData = {
  rich_content_id: number;
  page_index: number;
  title: string;
  position: number;
  view_count: number;
};

type AnalyticsData = {
  pages: PageViewData[];
  total_views: number;
  unique_viewers: number;
  by_page_and_date: Record<string, number>;
};

type ChartDataPoint = {
  title: string;
  views: number;
  pageIndex: number;
  label: string;
};

const ChartTooltip = ({ data }: { data: ChartDataPoint }) => (
  <>
    <div>
      <strong>{data.views}</strong> {data.views === 1 ? "view" : "views"}
    </div>
    <div className="block font-bold">{data.title}</div>
  </>
);

export const PageAnalytics = ({
  productId,
  onPageClick,
}: {
  productId: string;
  onPageClick?: (pageIndex: number) => void;
}) => {
  const [loading, setLoading] = React.useState(true);
  const [analyticsData, setAnalyticsData] = React.useState<AnalyticsData | null>(null);
  const [error, setError] = React.useState<string | null>(null);
  const [dateRange, setDateRange] = React.useState<"7d" | "30d" | "90d">("30d");

  const fetchAnalytics = React.useCallback(async () => {
    setLoading(true);
    setError(null);

    try {
      const endDate = new Date();
      const startDate = new Date();

      switch (dateRange) {
        case "7d":
          startDate.setDate(endDate.getDate() - 7);
          break;
        case "30d":
          startDate.setDate(endDate.getDate() - 30);
          break;
        case "90d":
          startDate.setDate(endDate.getDate() - 90);
          break;
      }

      const response = await request({
        url: Routes.product_content_page_analytics_path(productId, {
          params: {
            start_date: startDate.toISOString().split("T")[0],
            end_date: endDate.toISOString().split("T")[0],
          },
        }),
        method: "GET",
        accept: "json",
      });

      if (!response.ok) throw new Error("Failed to fetch analytics");

      const data = cast<AnalyticsData>(await response.json());
      setAnalyticsData(data);
    } catch (e) {
      setError("Failed to load analytics data");
      // eslint-disable-next-line no-console
      console.error(e);
    } finally {
      setLoading(false);
    }
  }, [productId, dateRange]);

  React.useEffect(() => {
    void fetchAnalytics();
  }, [fetchAnalytics]);

  const chartData = React.useMemo<ChartDataPoint[]>(() => {
    if (!analyticsData) return [];

    return analyticsData.pages.map((page, index) => ({
      title: page.title,
      views: page.view_count,
      pageIndex: page.page_index,
      label: index === 0 || index === analyticsData.pages.length - 1 ? page.title : "",
    }));
  }, [analyticsData]);

  const { tooltip, containerRef, dotRef, events } = useChartTooltip();
  const tooltipData = tooltip ? chartData[tooltip.index] : null;

  const maxViews = Math.max(...chartData.map((d) => d.views), 1);

  if (loading) {
    return (
      <div className="flex items-center justify-center py-12">
        <LoadingSpinner />
      </div>
    );
  }

  if (error) {
    return (
      <div className="py-8 text-center">
        <p className="text-muted">{error}</p>
        <Button onClick={() => void fetchAnalytics()} className="mt-4">
          Retry
        </Button>
      </div>
    );
  }

  if (!analyticsData || analyticsData.total_views === 0) {
    return (
      <div className="py-8 text-center">
        <Icon name="chart-line" className="mx-auto mb-4 text-muted" />
        <p className="text-muted">No page views yet</p>
        <p className="text-sm text-muted">Analytics will appear once customers start viewing your content</p>
      </div>
    );
  }

  return (
    <div className="space-y-6">
      {/* Header with stats and date range selector */}
      <div className="flex flex-wrap items-center justify-between gap-4">
        <div className="flex gap-6">
          <div>
            <div className="text-2xl font-bold">{analyticsData.total_views}</div>
            <div className="text-sm text-muted">Total Views</div>
          </div>
          <div>
            <div className="text-2xl font-bold">{analyticsData.unique_viewers}</div>
            <div className="text-sm text-muted">Unique Viewers</div>
          </div>
        </div>

        <div className="flex gap-2">
          {(["7d", "30d", "90d"] as const).map((range) => (
            <Button
              key={range}
              onClick={() => setDateRange(range)}
              color={dateRange === range ? "accent" : "ghost"}
              size="sm"
            >
              {range === "7d" ? "7 days" : range === "30d" ? "30 days" : "90 days"}
            </Button>
          ))}
        </div>
      </div>

      {/* Chart */}
      {chartData.length > 0 ? (
        <div className="rounded-lg border border-border p-4">
          <h3 className="mb-4 font-bold">Views per Page</h3>
          <Chart
            containerRef={containerRef}
            tooltip={tooltipData ? <ChartTooltip data={tooltipData} /> : null}
            tooltipPosition={tooltip?.position ?? null}
            data={chartData}
            maxBarSize={40}
            {...events}
          >
            <XAxis {...xAxisProps} dataKey="label" />
            <YAxis {...yAxisProps} orientation="right" />
            <Bar dataKey="views" radius={[4, 4, 0, 0]} cursor="pointer">
              {chartData.map((entry, index) => (
                <Cell
                  key={`cell-${index}`}
                  fill={`hsl(var(--color-accent-hsl) / ${0.3 + (entry.views / maxViews) * 0.7})`}
                  onClick={() => onPageClick?.(entry.pageIndex)}
                />
              ))}
            </Bar>
          </Chart>
        </div>
      ) : null}

      {/* Page list with view counts */}
      <div className="rounded-lg border border-border">
        <div className="border-b border-border p-4">
          <h3 className="font-bold">Page Performance</h3>
        </div>
        <div className="divide-y divide-border">
          {analyticsData.pages.map((page, index) => {
            const percentage = analyticsData.total_views > 0
              ? Math.round((page.view_count / analyticsData.total_views) * 100)
              : 0;

            return (
              <div
                key={page.rich_content_id}
                className={`flex items-center justify-between p-4 ${
                  onPageClick ? "cursor-pointer hover:bg-muted/50" : ""
                }`}
                onClick={() => onPageClick?.(page.page_index)}
              >
                <div className="flex-1">
                  <div className="font-medium">{page.title}</div>
                  <div className="text-sm text-muted">Page {page.page_index + 1}</div>
                </div>
                <div className="flex items-center gap-4">
                  <div className="text-right">
                    <div className="font-bold">{page.view_count}</div>
                    <div className="text-sm text-muted">{percentage}%</div>
                  </div>
                  {onPageClick ? (
                    <WithTooltip tip="Jump to page">
                      <Icon name="arrow-right" className="text-muted" />
                    </WithTooltip>
                  ) : null}
                </div>
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
};
