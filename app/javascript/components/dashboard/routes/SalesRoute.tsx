import React from "react";
import { Navigate } from "react-router-dom";

const SalesRoute: React.FC = () => {
  // Redirect sales to analytics
  return <Navigate to="/dashboard/sales" replace />;
};

export default SalesRoute;