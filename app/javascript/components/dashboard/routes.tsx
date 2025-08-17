import React from "react";
import { createBrowserRouter, Navigate } from "react-router-dom";

import { DashboardShell } from "./DashboardShell";
import { ErrorFallback } from "./shared/ErrorBoundary";

// Lazy load route components for better performance
const DashboardRoute = React.lazy(() => import("./routes/DashboardRoute"));
const ProductsRoute = React.lazy(() => import("./routes/ProductsRoute"));
const AnalyticsRoute = React.lazy(() => import("./routes/AnalyticsRoute"));
const AudienceRoute = React.lazy(() => import("./routes/AudienceRoute"));
const SalesRoute = React.lazy(() => import("./routes/SalesRoute"));
const BalanceRoute = React.lazy(() => import("./routes/BalanceRoute"));
const UTMLinksRoute = React.lazy(() => import("./routes/UTMLinksRoute"));

export const createDashboardRouter = () => {
  return createBrowserRouter([
    {
      path: "/",
      element: <DashboardShell />,
      errorElement: <ErrorFallback />,
      children: [
        {
          index: true,
          element: <Navigate to="/dashboard" replace />,
        },
        {
          path: "dashboard",
          children: [
            {
              index: true,
              element: <DashboardRoute />,
            },
            {
              path: "sales",
              element: <AnalyticsRoute />,
            },
            {
              path: "audience", 
              element: <AudienceRoute />,
            },
            {
              path: "utm_links/*",
              element: <UTMLinksRoute />,
            },
          ],
        },
        {
          path: "products/*",
          element: <ProductsRoute />,
        },
        {
          path: "balance",
          element: <BalanceRoute />,
        },
        {
          path: "sales",
          element: <Navigate to="/dashboard/sales" replace />,
        },
        {
          path: "analytics", 
          element: <Navigate to="/dashboard/sales" replace />,
        },
        {
          path: "audience",
          element: <Navigate to="/dashboard/audience" replace />,
        },
      ],
    },
  ]);
};

// Route guard component for protected routes
interface RouteGuardProps {
  children: React.ReactNode;
  requiredPolicy?: string;
  fallback?: React.ReactNode;
}

export const RouteGuard: React.FC<RouteGuardProps> = ({ 
  children, 
  requiredPolicy,
  fallback 
}) => {
  // This would check user permissions based on the policy
  // For now, we'll assume all routes are accessible
  // TODO: Implement policy checking logic
  
  return <>{children}</>;
};