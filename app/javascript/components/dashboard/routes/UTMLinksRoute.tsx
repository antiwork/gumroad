import React from "react";
import { Navigate, useLocation } from "react-router-dom";

const UTMLinksRoute: React.FC = () => {
  const location = useLocation();
  
  const target = `/dashboard/utm_links${location.pathname.replace(/^\/dashboard\/utm_links/, "")}${location.search}`;
  
  if (`${location.pathname}${location.search}` === target) {
    return null;
  }
  
  return <Navigate to={target} replace />;
};

export default UTMLinksRoute;