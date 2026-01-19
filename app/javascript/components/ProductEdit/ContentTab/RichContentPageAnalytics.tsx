import * as React from "react";
import { cast } from "ts-safe-cast";
import { request } from "$app/utils/request";
import { Card, CardContent, CardHeader, CardTitle } from "$app/components/ui/Card";
import { Icon } from "$app/components/Icons";
import { LoadingSpinner } from "$app/components/LoadingSpinner";

const formatNumber = (num: number): string => {
  return num.toLocaleString();
};

type PageStat = {
  page_id: string;
  page_title: string;
  view_count: number;
  position: number;
};

type AnalyticsData = {
  page_stats: PageStat[];
  total_views: Record<string, number>;
};

export const RichContentPageAnalytics = ({
  productPermalink,
  onPageClick,
}: {
  productPermalink: string;
  onPageClick?: (pageId: string) => void;
}) => {
  const [loading, setLoading] = React.useState(true);
  const [data, setData] = React.useState<AnalyticsData | null>(null);
  const [error, setError] = React.useState<string | null>(null);
  const [dateRange] = React.useState({
    start_date: new Date(Date.now() - 29 * 24 * 60 * 60 * 1000).toISOString().split("T")[0],
    end_date: new Date().toISOString().split("T")[0],
  });

  React.useEffect(() => {
    const fetchAnalytics = async () => {
      try {
        setLoading(true);
        setError(null);
        const response = await request({
          url: Routes.product_rich_content_analytics_index_path(productPermalink, {
            params: dateRange,
          }),
          method: "GET",
          accept: "json",
        });

        if (!response.ok) {
          throw new Error("Failed to fetch analytics");
        }

        const result = cast<AnalyticsData>(await response.json());
        setData(result);
      } catch (err) {
        setError(err instanceof Error ? err.message : "Failed to load analytics");
      } finally {
        setLoading(false);
      }
    };

    void fetchAnalytics();
  }, [productPermalink, dateRange]);

  if (loading) {
    return (
      <Card>
        <CardContent className="flex items-center justify-center p-8">
          <LoadingSpinner />
        </CardContent>
      </Card>
    );
  }

  if (error) {
    return (
      <Card>
        <CardContent className="p-4">
          <div className="text-red-600">{error}</div>
        </CardContent>
      </Card>
    );
  }

  if (!data || data.page_stats.length === 0) {
    return (
      <Card>
        <CardHeader>
          <CardTitle>Page View Analytics</CardTitle>
        </CardHeader>
        <CardContent>
          <div className="text-muted-foreground">
            No page views recorded yet. Page views will appear here once buyers start viewing your content pages.
          </div>
        </CardContent>
      </Card>
    );
  }

  const maxViews = Math.max(...data.page_stats.map((stat) => stat.view_count), 1);
  const totalViews = data.page_stats.reduce((sum, stat) => sum + stat.view_count, 0);

  return (
    <Card>
      <CardHeader>
        <CardTitle>
          <div className="flex items-center justify-between">
            <span>Page View Analytics</span>
            <span className="text-sm font-normal text-muted-foreground">Last 30 days</span>
          </div>
        </CardTitle>
      </CardHeader>
      <CardContent>
        <div className="mb-4 text-sm text-muted-foreground">
          Total views: <span className="font-semibold text-foreground">{formatNumber(totalViews)}</span>
        </div>
        <div className="space-y-4">
          {data.page_stats.map((stat) => {
            const percentage = maxViews > 0 ? (stat.view_count / maxViews) * 100 : 0;
            return (
              <div key={stat.page_id} className="space-y-2">
                <div className="flex items-center justify-between text-sm">
                  <button
                    type="button"
                    onClick={() => onPageClick?.(stat.page_id)}
                    className="flex items-center gap-2 text-left hover:text-blue-600 hover:underline"
                  >
                    <Icon name="file-text" className="h-4 w-4" />
                    <span className="font-medium">{stat.page_title}</span>
                  </button>
                  <span className="font-semibold">{formatNumber(stat.view_count)} views</span>
                </div>
                <div className="relative h-8 w-full overflow-hidden rounded-md bg-gray-200 dark:bg-gray-700">
                  <div
                    className="absolute left-0 top-0 h-full bg-blue-500 transition-all duration-300 hover:bg-blue-600"
                    style={{ width: `${percentage}%` }}
                    role="button"
                    tabIndex={0}
                    onClick={() => onPageClick?.(stat.page_id)}
                    onKeyDown={(e) => {
                      if (e.key === "Enter" || e.key === " ") {
                        e.preventDefault();
                        onPageClick?.(stat.page_id);
                      }
                    }}
                    aria-label={`${stat.page_title}: ${stat.view_count} views`}
                  >
                    {percentage > 15 && (
                      <div className="flex h-full items-center px-3 text-sm font-medium text-white">
                        {formatNumber(stat.view_count)}
                      </div>
                    )}
                  </div>
                </div>
              </div>
            );
          })}
        </div>
      </CardContent>
    </Card>
  );
};
