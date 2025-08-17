import React, { useEffect, useState } from "react";
import { useDashboardAPI } from "$app/services/api/dashboardAPI";
import { useDashboardState } from "$app/services/state/dashboardStore";
import { PageLoading } from "../shared/LoadingStates";
import { ErrorFallback } from "../shared/ErrorBoundary";

const AnalyticsRoute: React.FC = () => {
  const { fetchAnalyticsData, isLoading, getError } = useDashboardAPI();
  const state = useDashboardState();
  
  // Default to last 30 days
  const [dateRange, setDateRange] = useState(() => {
    const endDate = new Date();
    const startDate = new Date();
    startDate.setDate(startDate.getDate() - 30);
    
    return {
      start: startDate.toISOString().split('T')[0],
      end: endDate.toISOString().split('T')[0],
    };
  });

  useEffect(() => {
    fetchAnalyticsData(dateRange.start, dateRange.end);
  }, [fetchAnalyticsData, dateRange.start, dateRange.end]);

  const cacheKey = `analytics_${dateRange.start}_${dateRange.end}`;
  const analyticsData = state.cache[cacheKey];
  const isLoadingAnalytics = isLoading(cacheKey);
  const error = getError(cacheKey);

  if (error) {
    return <ErrorFallback error={new Error(error)} />;
  }

  if (isLoadingAnalytics && !analyticsData) {
    return <PageLoading message="Loading analytics..." />;
  }

  // For now, redirect to the existing analytics page
  // TODO: Create a React-based analytics component
  useEffect(() => {
    if (!isLoadingAnalytics && !analyticsData) {
      // Fallback to server-rendered page
      window.location.href = "/dashboard/sales";
    }
  }, [isLoadingAnalytics, analyticsData]);

  return (
    <div className="dashboard-spa-analytics">
      <div className="analytics-header">
        <h1>Sales Analytics</h1>
        <div className="date-range-picker">
          <input
            type="date"
            value={dateRange.start}
            onChange={(e) => setDateRange(prev => ({ ...prev, start: e.target.value }))}
          />
          <span>to</span>
          <input
            type="date"
            value={dateRange.end}
            onChange={(e) => setDateRange(prev => ({ ...prev, end: e.target.value }))}
          />
        </div>
      </div>

      {analyticsData ? (
        <div className="analytics-content">
          {/* TODO: Implement analytics charts and data visualization */}
          <pre>{JSON.stringify(analyticsData, null, 2)}</pre>
        </div>
      ) : (
        <PageLoading message="Loading analytics data..." />
      )}
    </div>
  );
};

export default AnalyticsRoute;