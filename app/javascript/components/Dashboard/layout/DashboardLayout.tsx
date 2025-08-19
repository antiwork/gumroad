import * as React from "react";
import { Outlet, useLocation } from "react-router-dom";
import { DashboardSidebar } from "./DashboardSidebar";

export const DashboardLayout: React.FC = () => {
  const location = useLocation();

  // Get page title based on current route
  const getPageTitle = () => {
    switch (location.pathname) {
      case "/dashboard":
        return "Dashboard";
      case "/dashboard/sales":
        return "Sales Analytics";
      case "/dashboard/audience":
        return "Audience";
      case "/dashboard/utm_links":
        return "UTM Links";
      default:
        return "Dashboard";
    }
  };

  return (
    <div className="dashboard-spa-container" style={{ display: "flex", minHeight: "100vh" }}>
      {/* Sidebar Navigation */}
      <DashboardSidebar currentPath={location.pathname} />

      {/* Main Content Area */}
      <div className="dashboard-main-content" style={{ flex: 1, marginLeft: "240px" }}>
        {/* Page Header */}
        <header className="dashboard-header" style={{
          padding: "1rem 2rem",
          borderBottom: "1px solid #e5e7eb",
          backgroundColor: "white"
        }}>
          <h1 style={{ margin: 0, fontSize: "1.5rem", fontWeight: "600" }}>
            {getPageTitle()}
          </h1>
        </header>

        {/* Page Content */}
        <div className="dashboard-content" style={{ padding: "2rem" }} data-testid="dashboard-content">
          <Outlet />
        </div>
      </div>
    </div>
  );
};

export default DashboardLayout;
