import React, { useEffect } from "react";
import { useLocation } from "react-router-dom";

const UTMLinksRoute: React.FC = () => {
  const location = useLocation();

  useEffect(() => {
    // UTM Links already uses React Router, so redirect to existing implementation
    window.location.href = `/dashboard/utm_links${location.pathname.replace('/dashboard/utm_links', '')}${location.search}`;
  }, [location]);

  return (
    <div className="dashboard-spa-utm-links">
      <h1>UTM Links</h1>
      <p>Redirecting to UTM Links page...</p>
    </div>
  );
};

export default UTMLinksRoute;