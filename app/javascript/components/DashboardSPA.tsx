import React from "react";
import { BrowserRouter, Routes, Route, Navigate } from "react-router-dom";

// Import existing components
import { DashboardPage } from "./server-components/DashboardPage";

// Import new SPA components (to be created)
import { DashboardLayout } from "./dashboard/DashboardLayout";
import { AnalyticsPage } from "./dashboard/AnalyticsPage";
import { AudiencePage } from "./dashboard/AudiencePage";
import { UTMLinksPage } from "./dashboard/UTMLinksPage";
import { ProductsPage } from "./dashboard/ProductsPage";

interface DashboardSPAProps {
  initialProps?: any;
}

export const DashboardSPA: React.FC<DashboardSPAProps> = ({ initialProps }) => {
  return (
    <BrowserRouter basename="/dashboard">
      <DashboardLayout>
        <Routes>
          {/* Main dashboard home */}
          <Route 
            path="/" 
            element={<DashboardPage {...initialProps} />} 
          />
          
          {/* Analytics section */}
          <Route 
            path="/sales" 
            element={<AnalyticsPage />} 
          />
          
          {/* Audience section */}
          <Route 
            path="/audience" 
            element={<AudiencePage />} 
          />
          
          {/* UTM Links section */}
          <Route 
            path="/utm_links" 
            element={<UTMLinksPage />} 
          />
          
          {/* Products section */}
          <Route 
            path="/products" 
            element={<ProductsPage />} 
          />
          
          {/* Catch all - redirect to home */}
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </DashboardLayout>
    </BrowserRouter>
  );
};

// Register the component for server-side rendering
export default DashboardSPA;
