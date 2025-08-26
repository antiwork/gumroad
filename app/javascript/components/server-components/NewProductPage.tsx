import * as React from "react";
import { useLoaderData } from "react-router-dom";

import { useFeatureFlags } from "$app/components/FeatureFlags";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { NavigationButton } from "../Button";

export const NewProductPage: React.FC = () => {
  const { dashboard_spa_enabled } = useFeatureFlags();
  const currentSeller = useCurrentSeller();

  // If SPA is disabled, show fallback
  if (!dashboard_spa_enabled) {
    return (
      <div className="new-product-page-fallback">
        <p>New Product Page SPA is currently disabled. Please refresh the page to use the server-rendered version.</p>
      </div>
    );
  }

  return (
    <div className="new-product-page">
      <header>
        <h1>Create New Product</h1>
        <p>What are you creating today?</p>
        
        <div className="actions">
          <NavigationButton href="/products" color="secondary">
            Back to Products
          </NavigationButton>
        </div>
      </header>
      
      <div className="new-product-content">
        <div className="product-types">
          <h2>Choose Product Type</h2>
          <p>Welcome to the product creation page, {currentSeller?.name || 'Creator'}!</p>
          
          {/* Placeholder for product type selection - this would be populated with actual options */}
          <div className="product-type-options">
            <div className="product-type-option">
              <h3>Digital Product</h3>
              <p>Create a one-time digital product</p>
            </div>
            <div className="product-type-option">
              <h3>Membership</h3>
              <p>Create a recurring subscription</p>
            </div>
            <div className="product-type-option">
              <h3>Bundle</h3>
              <p>Package multiple products together</p>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};
