import * as React from "react";
import { useLoaderData } from "react-router-dom";

import { useFeatureFlags } from "$app/components/FeatureFlags";
import { useCurrentSeller } from "$app/components/CurrentSeller";

export const DiscoverPage: React.FC = () => {
  const { dashboard_spa_enabled } = useFeatureFlags();
  const currentSeller = useCurrentSeller();

  // If SPA is disabled, show fallback
  if (!dashboard_spa_enabled) {
    return (
      <div className="discover-page-fallback">
        <p>Discover Page SPA is currently disabled. Please refresh the page to use the server-rendered version.</p>
      </div>
    );
  }

  return (
    <div className="discover-page">
      <header>
        <h1>Discover</h1>
        <p>Find amazing products from other creators</p>
      </header>
      
      <div className="discover-content">
        <div className="discover-overview">
          <h2>Explore Products</h2>
          <p>Welcome to the discover page, {currentSeller?.name || 'Creator'}!</p>
          
          {/* Placeholder for discover content - this would be populated with actual data */}
          <div className="discover-products">
            <div className="discover-product">
              <h3>Loading Discover Content...</h3>
              <p>Amazing products from other creators will appear here once loaded.</p>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};
