import React from "react";
import ReactDOM from "react-dom/client";
import { RouterProvider } from "react-router-dom";

import { createDashboardRouter } from "$app/components/dashboard/routes";
import { DashboardProvider } from "$app/services/state/dashboardStore";
import BasePage from "$app/utils/base_page";

// Initialize base page functionality
BasePage.initialize();

// Create router instance
const router = createDashboardRouter();

// Initialize SPA when DOM is ready
document.addEventListener("DOMContentLoaded", () => {
  const rootElement = document.getElementById("dashboard-spa-root");
  
  if (rootElement) {
    const root = ReactDOM.createRoot(rootElement);
    
    root.render(
      React.createElement(DashboardProvider, { children: 
        React.createElement(RouterProvider, { router })
      })
    );
  } else {
    console.error("Dashboard SPA root element not found");
  }
});

// Handle navigation performance
window.addEventListener("beforeunload", () => {
  // Clean up any ongoing requests or timers
  // This helps with navigation performance
});

// Hot module replacement for development
if (module.hot) {
  module.hot.accept();
}