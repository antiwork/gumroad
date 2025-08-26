import * as React from "react";
import { RouterProvider, createBrowserRouter, RouteObject } from "react-router-dom";
import { StaticRouterProvider } from "react-router-dom/server";

import { register, GlobalProps, buildStaticRouter } from "$app/utils/serverComponentUtil";
import { useFeatureFlags } from "$app/components/FeatureFlags";

import { DashboardPage } from "./DashboardPage";
import { ProductsPage } from "./ProductsPage";
import { SalesDashboard } from "./SalesDashboard";
import { NewProductPage } from "./NewProductPage";
import { DiscoverPage } from "./DiscoverPage";
import { LibraryPage } from "./LibraryPage";
import { DashboardLayout } from "./DashboardSPA/DashboardLayout";

// Define the routes for the SPA
const routes: RouteObject[] = [
  {
    path: "/dashboard",
    element: <DashboardLayout />,
    children: [
      {
        index: true,
        element: <DashboardPage />,
      },
      {
        path: "sales",
        element: <SalesDashboard />,
      },
    ],
  },
  {
    path: "/products",
    element: <DashboardLayout />,
    children: [
      {
        index: true,
        element: <ProductsPage />,
      },
    ],
  },
  {
    path: "/products/new",
    element: <DashboardLayout />,
    children: [
      {
        index: true,
        element: <NewProductPage />,
      },
    ],
  },
  {
    path: "/discover",
    element: <DashboardLayout />,
    children: [
      {
        index: true,
        element: <DiscoverPage />,
      },
    ],
  },
  {
    path: "/library",
    element: <DashboardLayout />,
    children: [
      {
        index: true,
        element: <LibraryPage />,
      },
    ],
  },
];

// Main SPA component
const DashboardSPA = () => {
  const { dashboard_spa_enabled } = useFeatureFlags();

  // If SPA is disabled, render a fallback message
  if (!dashboard_spa_enabled) {
    return (
      <div className="dashboard-spa-fallback">
        <p>Dashboard SPA is currently disabled. Please refresh the page to use the server-rendered version.</p>
      </div>
    );
  }

  const router = createBrowserRouter(routes);

  return <RouterProvider router={router} />;
};

// SSR component for server-side rendering
const DashboardSPARouter = async (global: GlobalProps) => {
  const { router, context } = await buildStaticRouter(global, routes);
  
  const component = () => (
    <StaticRouterProvider router={router} context={context} nonce={global.csp_nonce} />
  );
  
  component.displayName = "DashboardSPARouter";
  return component;
};

export default register({
  component: DashboardSPA,
  ssrComponent: DashboardSPARouter,
  propParser: () => ({}),
});
