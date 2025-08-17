import React, { useEffect } from "react";
import { useDashboardAPI } from "$app/services/api/dashboardAPI";
import { useDashboardState } from "$app/services/state/dashboardStore";
import { PageLoading } from "../shared/LoadingStates";
import { ErrorFallback } from "../shared/ErrorBoundary";

const AudienceRoute: React.FC = () => {
  const { fetchAudienceData, isLoading, getError } = useDashboardAPI();
  const state = useDashboardState();

  useEffect(() => {
    fetchAudienceData();
  }, [fetchAudienceData]);

  const audienceData = state.cache.audience;
  const isLoadingAudience = isLoading("audience");
  const error = getError("audience");

  if (error) {
    return <ErrorFallback error={new Error(error)} />;
  }

  if (isLoadingAudience && !audienceData) {
    return <PageLoading message="Loading audience data..." />;
  }

  // For now, redirect to the existing audience page
  // TODO: Create a React-based audience component
  useEffect(() => {
    if (!isLoadingAudience && !audienceData) {
      // Fallback to server-rendered page
      window.location.href = "/dashboard/audience";
    }
  }, [isLoadingAudience, audienceData]);

  return (
    <div className="dashboard-spa-audience">
      <h1>Audience</h1>
      
      {audienceData ? (
        <div className="audience-content">
          {/* TODO: Implement audience components */}
          <pre>{JSON.stringify(audienceData, null, 2)}</pre>
        </div>
      ) : (
        <PageLoading message="Loading audience data..." />
      )}
    </div>
  );
};

export default AudienceRoute;