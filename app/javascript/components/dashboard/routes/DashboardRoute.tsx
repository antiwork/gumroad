import React, { useEffect } from "react";
import { useDashboardAPI } from "$app/services/api/dashboardAPI";
import { useDashboardState } from "$app/services/state/dashboardStore";
import { PageLoading, StatsLoading } from "../shared/LoadingStates";
import { ErrorFallback } from "../shared/ErrorBoundary";

// Import existing dashboard components
import { DashboardPage } from "$app/components/server-components/DashboardPage";

const DashboardRoute: React.FC = () => {
  const { fetchDashboardData, fetchDashboardStats, isLoading, getError } = useDashboardAPI();
  const state = useDashboardState();

  useEffect(() => {
    // Fetch initial dashboard data
    fetchDashboardData();
    fetchDashboardStats();
  }, [fetchDashboardData, fetchDashboardStats]);

  const dashboardData = state.cache.dashboard;
  const dashboardStats = state.cache.dashboard_stats;
  const isLoadingDashboard = isLoading("dashboard");
  const isLoadingStats = isLoading("dashboard_stats");
  const error = getError("dashboard") || getError("dashboard_stats");

  if (error) {
    return <ErrorFallback error={new Error(error)} />;
  }

  if (isLoadingDashboard && !dashboardData) {
    return <PageLoading message="Loading dashboard..." />;
  }

  // Show existing dashboard with real-time stats updates
  if (dashboardData) {
    // Merge real-time stats if available
    const enhancedData = dashboardStats ? {
      ...dashboardData,
      // Update balances with real-time data
      balances: {
        ...dashboardData.balances,
        // Add any real-time updates here
      }
    } : dashboardData;

    return <DashboardPage {...enhancedData} />;
  }

  if (isLoadingStats && !dashboardStats) {
    return <StatsLoading />;
  }

  return <PageLoading message="Loading dashboard..." />;
};

export default DashboardRoute;