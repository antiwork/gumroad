import * as React from "react";
import { useLoaderData } from "react-router-dom";

import { useFeatureFlags } from "$app/components/FeatureFlags";
import { useCurrentSeller } from "$app/components/CurrentSeller";

export const SalesDashboard: React.FC = () => {
  const { dashboard_spa_enabled } = useFeatureFlags();
  const currentSeller = useCurrentSeller();

  // If SPA is disabled, show fallback
  if (!dashboard_spa_enabled) {
    return (
      <div className="sales-dashboard-fallback">
        <p>Sales Dashboard SPA is currently disabled. Please refresh the page to use the server-rendered version.</p>
      </div>
    );
  }

  return (
    <div className="sales-dashboard">
      <header>
        <h1>Sales Analytics</h1>
        <p>Track your sales performance and revenue metrics</p>
      </header>
      
      <div className="sales-content">
        <div className="sales-overview">
          <h2>Sales Overview</h2>
          <p>Welcome to your sales dashboard, {currentSeller?.name || 'Creator'}!</p>
          
          {/* Placeholder for sales data - this would be populated with actual data */}
          <div className="sales-stats">
            <div className="stat-card">
              <h3>Total Sales</h3>
              <p className="stat-value">Loading...</p>
            </div>
            <div className="stat-card">
              <h3>Revenue</h3>
              <p className="stat-value">Loading...</p>
            </div>
            <div className="stat-card">
              <h3>Products Sold</h3>
              <p className="stat-value">Loading...</p>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};
