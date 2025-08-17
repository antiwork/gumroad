import React, { Suspense, useEffect, useState } from "react";
import { Outlet, useLocation, useNavigate } from "react-router-dom";
import cx from "classnames";

import { useLoggedInUser } from "$app/components/LoggedInUser";
import { Icon } from "$app/components/Icons";
import { LoadingSpinner } from "./shared/LoadingStates";
import { DashboardNav } from "./navigation/DashboardNav";
import { Breadcrumbs } from "./navigation/Breadcrumbs";
import { useDashboardStore } from "$app/services/state/dashboardStore";
import { ErrorBoundary } from "./shared/ErrorBoundary";

export const DashboardShell: React.FC = () => {
  const location = useLocation();
  const navigate = useNavigate();
  const loggedInUser = useLoggedInUser();
  const [isNavigating, setIsNavigating] = useState(false);
  const { initializeStore, clearCache } = useDashboardStore();

  useEffect(() => {
    if (loggedInUser) {
      initializeStore(loggedInUser);
    }
  }, [loggedInUser, initializeStore]);

  useEffect(() => {
    setIsNavigating(true);
    const timer = setTimeout(() => setIsNavigating(false), 300);
    return () => clearTimeout(timer);
  }, [location.pathname]);

  useEffect(() => {
    const handleKeyPress = (e: KeyboardEvent) => {
      if (e.metaKey || e.ctrlKey) {
        switch (e.key) {
          case "k":
            e.preventDefault();
            // TODO: Open command palette
            break;
          case "1":
            e.preventDefault();
            navigate("/dashboard");
            break;
          case "2":
            e.preventDefault();
            navigate("/products");
            break;
          case "3":
            e.preventDefault();
            navigate("/dashboard/sales");
            break;
        }
      }
    };

    window.addEventListener("keydown", handleKeyPress);
    return () => window.removeEventListener("keydown", handleKeyPress);
  }, [navigate]);

  if (!loggedInUser) {
    return (
      <div className="dashboard-spa-loading">
        <LoadingSpinner size="large" />
      </div>
    );
  }

  return (
    <div className="dashboard-spa-container">
      <DashboardNav currentPath={location.pathname} />
      
      <div className="dashboard-spa-main">
        <div className="dashboard-spa-header">
          <Breadcrumbs />
          
          <div className="dashboard-spa-header-actions">
            <button
              className="button ghost"
              onClick={() => clearCache()}
              title="Refresh data"
            >
              <Icon name="arrows-clockwise" />
            </button>
            
            <button
              className="button ghost"
              onClick={() => {
                // TODO: Open command palette
              }}
              title="Quick actions (⌘K)"
            >
              <Icon name="solid-search" />
            </button>
          </div>
        </div>

        <div 
          className={cx("dashboard-spa-content", {
            "is-navigating": isNavigating
          })}
        >
          <ErrorBoundary>
            <Suspense fallback={<LoadingSpinner />}>
              <Outlet />
            </Suspense>
          </ErrorBoundary>
        </div>
      </div>
    </div>
  );
};