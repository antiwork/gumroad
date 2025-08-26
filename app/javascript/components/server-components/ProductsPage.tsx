import * as React from "react";
import { useLoaderData } from "react-router-dom";

import { useFeatureFlags } from "$app/components/FeatureFlags";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { NavigationButton } from "../Button";

export const ProductsPage: React.FC = () => {
  const { dashboard_spa_enabled } = useFeatureFlags();
  const currentSeller = useCurrentSeller();

  // If SPA is disabled, show fallback
  if (!dashboard_spa_enabled) {
    return (
      <div className="products-page-fallback">
        <p>Products Page SPA is currently disabled. Please refresh the page to use the server-rendered version.</p>
      </div>
    );
  }

  return (
    <div className="products-page">
      <header>
        <h1>Products</h1>
        <p>Manage your digital products and memberships</p>
        
        <div className="actions">
          <NavigationButton href="/products/new" color="accent">
            Create New Product
          </NavigationButton>
        </div>
      </header>
      
      <div className="products-content">
        <div className="products-overview">
          <h2>Your Products</h2>
          <p>Welcome to your products page, {currentSeller?.name || 'Creator'}!</p>
          
          {/* Placeholder for products list - this would be populated with actual data */}
          <div className="products-list">
            <div className="product-item">
              <h3>Loading Products...</h3>
              <p>Your products will appear here once loaded.</p>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};
