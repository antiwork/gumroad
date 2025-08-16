import React from "react";
import { useLocation } from "react-router-dom";

import { DashboardSidebar } from "./DashboardSidebar";
import { DashboardHeader } from "./DashboardHeader";

interface DashboardLayoutProps {
  children: React.ReactNode;
}

export const DashboardLayout: React.FC<DashboardLayoutProps> = ({ children }) => {
  const location = useLocation();

  return (
    <div className="dashboard-spa-layout min-h-screen bg-gray-50">
      {/* Header */}
      <DashboardHeader />
      
      <div className="flex">
        {/* Sidebar */}
        <DashboardSidebar currentPath={location.pathname} />
        
        {/* Main content */}
        <main className="flex-1 p-6 ml-64">
          <div className="dashboard-content">
            {children}
          </div>
        </main>
      </div>
    </div>
  );
};
