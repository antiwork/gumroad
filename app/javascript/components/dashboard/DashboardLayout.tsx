import React from "react";
import { useLocation } from "react-router-dom";

import { DashboardHeader } from "./DashboardHeader";
import { DashboardSidebar } from "./DashboardSidebar";

interface DashboardLayoutProps {
  children: React.ReactNode;
}

export const DashboardLayout: React.FC<DashboardLayoutProps> = ({ children }) => {
  const location = useLocation();

  return (
    <div className="dashboard-spa-layout bg-gray-50 min-h-screen">
      {/* Header */}
      <DashboardHeader />

      <div className="flex">
        {/* Sidebar */}
        <DashboardSidebar currentPath={location.pathname} />

        {/* Main content */}
        <main className="ml-64 flex-1 p-6">
          <div className="dashboard-content">{children}</div>
        </main>
      </div>
    </div>
  );
};
