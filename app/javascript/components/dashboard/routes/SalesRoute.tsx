import React, { useEffect } from "react";
import { useDashboardAPI } from "$app/services/api/dashboardAPI";
import { useDashboardState } from "$app/services/state/dashboardStore";
import { PageLoading } from "../shared/LoadingStates";
import { ErrorFallback } from "../shared/ErrorBoundary";

const SalesRoute: React.FC = () => {
  const { fetchAnalyticsData, isLoading, getError } = useDashboardAPI();
  const state = useDashboardState();

  useEffect(() => {
    fetchAnalyticsData();
  }, [fetchAnalyticsData]);

  const analyticsData = state.cache.analytics;
  const isLoadingAnalytics = isLoading("analytics");
  const error = getError("analytics");

  if (error) {
    return <ErrorFallback error={new Error(error)} />;
  }

  if (isLoadingAnalytics) {
    return <PageLoading message="Loading sales data..." />;
  }

  return (
    <div className="dashboard-spa-sales">
      <h1>Sales Analytics</h1>
      
      {analyticsData ? (
        <div className="sales-content">
          {/* TODO: Implement sales analytics components */}
          <pre>{JSON.stringify(analyticsData, null, 2)}</pre>
        </div>
      ) : (
        <div className="empty-state">
          <p>No sales data available</p>
        </div>
      )}
    </div>
  );
};

export default SalesRoute;