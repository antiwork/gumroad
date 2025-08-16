import React, { useState, useEffect } from "react";

interface AnalyticsData {
  revenue: number;
  sales: number;
  views: number;
  conversion: number;
}

export const AnalyticsPage: React.FC = () => {
  const [data, setData] = useState<AnalyticsData | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const fetchAnalytics = async () => {
      try {
        setLoading(true);

        // Use actual API endpoint
        const response = await fetch("/internal/dashboard/analytics", {
          method: "GET",
          headers: {
            "Content-Type": "application/json",
            "X-Requested-With": "XMLHttpRequest",
          },
          credentials: "same-origin",
        });

        if (!response.ok) {
          throw new Error(`HTTP ${response.status}: ${response.statusText}`);
        }

        // eslint-disable-next-line @typescript-eslint/no-unsafe-assignment
        const apiData = await response.json();
        setData({
          // eslint-disable-next-line @typescript-eslint/no-unsafe-member-access
          revenue: Number(apiData.revenue) || 0,
          // eslint-disable-next-line @typescript-eslint/no-unsafe-member-access
          sales: Number(apiData.sales) || 0,
          // eslint-disable-next-line @typescript-eslint/no-unsafe-member-access
          views: Number(apiData.views) || 0,
          // eslint-disable-next-line @typescript-eslint/no-unsafe-member-access
          conversion: Number(apiData.conversion) || 0,
        });
      } catch (err) {
        // eslint-disable-next-line no-console
        console.error("Analytics fetch error:", err);
        const errorMessage = err instanceof Error ? err.message : "Unknown error";
        setError(`Failed to load analytics data: ${errorMessage}`);

        // Fallback to mock data for demo
        setData({
          revenue: 12450,
          sales: 150,
          views: 2340,
          conversion: 6.4,
        });
      } finally {
        setLoading(false);
      }
    };

    void fetchAnalytics();
  }, []);

  if (loading) {
    return (
      <div className="analytics-page">
        <div className="flex h-64 items-center justify-center">
          <div className="h-8 w-8 animate-spin rounded-full border-b-2 border-blue-600"></div>
          <span className="text-gray-600 ml-2">Loading analytics...</span>
        </div>
      </div>
    );
  }

  if (error) {
    return (
      <div className="analytics-page">
        <div className="bg-red-50 border-red-200 rounded-lg border p-4">
          <p className="text-red-700">{error}</p>
        </div>
      </div>
    );
  }

  return (
    <div className="analytics-page">
      <div className="mb-8 grid grid-cols-1 gap-6 md:grid-cols-2 lg:grid-cols-4">
        {/* Revenue Card */}
        <div className="border-gray-200 rounded-lg border bg-white p-6">
          <h3 className="text-gray-500 text-sm font-medium">Total Revenue</h3>
          <p className="text-gray-900 text-2xl font-bold">${data?.revenue.toLocaleString()}</p>
          <p className="text-green-600 mt-1 text-xs">+12% from last month</p>
        </div>

        {/* Sales Card */}
        <div className="border-gray-200 rounded-lg border bg-white p-6">
          <h3 className="text-gray-500 text-sm font-medium">Total Sales</h3>
          <p className="text-gray-900 text-2xl font-bold">{data?.sales}</p>
          <p className="text-green-600 mt-1 text-xs">+8% from last month</p>
        </div>

        {/* Views Card */}
        <div className="border-gray-200 rounded-lg border bg-white p-6">
          <h3 className="text-gray-500 text-sm font-medium">Page Views</h3>
          <p className="text-gray-900 text-2xl font-bold">{data?.views.toLocaleString()}</p>
          <p className="mt-1 text-xs text-blue-600">+15% from last month</p>
        </div>

        {/* Conversion Card */}
        <div className="border-gray-200 rounded-lg border bg-white p-6">
          <h3 className="text-gray-500 text-sm font-medium">Conversion Rate</h3>
          <p className="text-gray-900 text-2xl font-bold">{data?.conversion}%</p>
          <p className="text-green-600 mt-1 text-xs">+2.1% from last month</p>
        </div>
      </div>

      {/* Charts Section */}
      <div className="border-gray-200 rounded-lg border bg-white p-6">
        <h2 className="text-gray-900 mb-4 text-lg font-semibold">Sales Chart</h2>
        <div className="text-gray-500 flex h-64 items-center justify-center">
          📈 Chart component will be implemented here
        </div>
      </div>
    </div>
  );
};
