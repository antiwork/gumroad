import * as React from "react";
import { useLoaderData } from "react-router-dom";

import { useFeatureFlags } from "$app/components/FeatureFlags";
import { useCurrentSeller } from "$app/components/CurrentSeller";

export const LibraryPage: React.FC = () => {
  const { dashboard_spa_enabled } = useFeatureFlags();
  const currentSeller = useCurrentSeller();

  // If SPA is disabled, show fallback
  if (!dashboard_spa_enabled) {
    return (
      <div className="library-page-fallback">
        <p>Library Page SPA is currently disabled. Please refresh the page to use the server-rendered version.</p>
      </div>
    );
  }

  return (
    <div className="library-page">
      <header>
        <h1>Library</h1>
        <p>Your purchased products and content</p>
      </header>
      
      <div className="library-content">
        <div className="library-overview">
          <h2>Your Library</h2>
          <p>Welcome to your library, {currentSeller?.name || 'Creator'}!</p>
          
          {/* Placeholder for library content - this would be populated with actual data */}
          <div className="library-items">
            <div className="library-item">
              <h3>Loading Library Content...</h3>
              <p>Your purchased products and content will appear here once loaded.</p>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};
