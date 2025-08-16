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
        const response = await fetch('/internal/dashboard/analytics', {
          method: 'GET',
          headers: {
            'Content-Type': 'application/json',
            'X-Requested-With': 'XMLHttpRequest'
          },
          credentials: 'same-origin'
        });
        
        if (!response.ok) {
          throw new Error(`HTTP ${response.status}: ${response.statusText}`);
        }
        
        const apiData = await response.json();
        setData({
          revenue: apiData.revenue || 0,
          sales: apiData.sales || 0,
          views: apiData.views || 0,
          conversion: apiData.conversion || 0
        });
      } catch (err) {
        console.error('Analytics fetch error:', err);
        const errorMessage = err instanceof Error ? err.message : 'Unknown error';
        setError(`Failed to load analytics data: ${errorMessage}`);
        
        // Fallback to mock data for demo
        setData({
          revenue: 12450,
          sales: 150,
          views: 2340,
          conversion: 6.4
        });
      } finally {
        setLoading(false);
      }
    };

    fetchAnalytics();
  }, []);

  if (loading) {
    return (
      <div className="analytics-page">
        <div className="flex items-center justify-center h-64">
          <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-blue-600"></div>
          <span className="ml-2 text-gray-600">Loading analytics...</span>
        </div>
      </div>
    );
  }

  if (error) {
    return (
      <div className="analytics-page">
        <div className="bg-red-50 border border-red-200 rounded-lg p-4">
          <p className="text-red-700">{error}</p>
        </div>
      </div>
    );
  }

  return (
    <div className="analytics-page">
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6 mb-8">
        {/* Revenue Card */}
        <div className="bg-white p-6 rounded-lg border border-gray-200">
          <h3 className="text-sm font-medium text-gray-500">Total Revenue</h3>
          <p className="text-2xl font-bold text-gray-900">${data?.revenue.toLocaleString()}</p>
          <p className="text-xs text-green-600 mt-1">+12% from last month</p>
        </div>

        {/* Sales Card */}
        <div className="bg-white p-6 rounded-lg border border-gray-200">
          <h3 className="text-sm font-medium text-gray-500">Total Sales</h3>
          <p className="text-2xl font-bold text-gray-900">{data?.sales}</p>
          <p className="text-xs text-green-600 mt-1">+8% from last month</p>
        </div>

        {/* Views Card */}
        <div className="bg-white p-6 rounded-lg border border-gray-200">
          <h3 className="text-sm font-medium text-gray-500">Page Views</h3>
          <p className="text-2xl font-bold text-gray-900">{data?.views.toLocaleString()}</p>
          <p className="text-xs text-blue-600 mt-1">+15% from last month</p>
        </div>

        {/* Conversion Card */}
        <div className="bg-white p-6 rounded-lg border border-gray-200">
          <h3 className="text-sm font-medium text-gray-500">Conversion Rate</h3>
          <p className="text-2xl font-bold text-gray-900">{data?.conversion}%</p>
          <p className="text-xs text-green-600 mt-1">+2.1% from last month</p>
        </div>
      </div>

      {/* Charts Section */}
      <div className="bg-white rounded-lg border border-gray-200 p-6">
        <h2 className="text-lg font-semibold text-gray-900 mb-4">Sales Chart</h2>
        <div className="h-64 flex items-center justify-center text-gray-500">
          📈 Chart component will be implemented here
        </div>
      </div>
    </div>
  );
};
