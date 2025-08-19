import * as React from "react";
import { BrowserRouter, Routes, Route, Navigate } from "react-router-dom";
import { DashboardLayout } from "./layout/DashboardLayout";
import { DashboardHomePage } from "./pages/DashboardHomePage";
import { AnalyticsPage } from "./pages/AnalyticsPage";
import { AudiencePage } from "./pages/AudiencePage";
import { UTMLinksPage } from "./pages/UTMLinksPage";

export const DashboardSPA: React.FC = () => {
  return (
    <BrowserRouter>
      <Routes>
        <Route path="/dashboard" element={<DashboardLayout />}>
          <Route index element={<DashboardHomePage />} />
          <Route path="sales" element={<AnalyticsPage />} />
          <Route path="audience" element={<AudiencePage />} />
          <Route path="utm_links" element={<UTMLinksPage />} />
          {/* Redirect legacy routes */}
          <Route path="analytics" element={<Navigate to="/dashboard/sales" replace />} />
        </Route>
        {/* Fallback for any unmatched routes */}
        <Route path="*" element={<Navigate to="/dashboard" replace />} />
      </Routes>
    </BrowserRouter>
  );
};

export default DashboardSPA;
