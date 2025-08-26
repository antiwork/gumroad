import * as React from "react";
import { Outlet, useLocation, useNavigate } from "react-router-dom";

import { useFeatureFlags } from "$app/components/FeatureFlags";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { useAppDomain } from "$app/components/DomainSettings";
import { startTrackingForGumroad } from "$app/data/google_analytics";

import { Nav } from "../Nav";
import { Icon } from "../Icons";

// Navigation items for the dashboard
const NAV_ITEMS = [
  { path: "/dashboard", label: "Dashboard", icon: "chart-line" as const },
  { path: "/products", label: "Products", icon: "box" as const },
  { path: "/dashboard/sales", label: "Sales", icon: "chart-bar" as const },
  { path: "/discover", label: "Discover", icon: "compass" as const },
  { path: "/library", label: "Library", icon: "book" as const },
];

export const DashboardLayout: React.FC = () => {
  const location = useLocation();
  const navigate = useNavigate();
  const { dashboard_spa_enabled } = useFeatureFlags();
  const loggedInUser = useLoggedInUser();
  const currentSeller = useCurrentSeller();
  const appDomain = useAppDomain();

  // Track page views for analytics
  React.useEffect(() => {
    if (dashboard_spa_enabled) {
      // Emit client-side page_view analytics
      startTrackingForGumroad();
      
      // Track route change
      if (window.gtag) {
        window.gtag('config', 'GA_MEASUREMENT_ID', {
          page_path: location.pathname + location.search,
        });
      }
    }
  }, [location.pathname, location.search, dashboard_spa_enabled]);

  // Focus management on route change
  React.useEffect(() => {
    // Move focus to the main heading on route change
    const mainHeading = document.querySelector('main h1');
    if (mainHeading) {
      (mainHeading as HTMLElement).focus();
    }
  }, [location.pathname]);

  // Handle navigation clicks
  const handleNavClick = (ev: React.MouseEvent<HTMLAnchorElement>, path: string) => {
    ev.preventDefault();
    
    if (dashboard_spa_enabled) {
      // Use React Router navigation
      navigate(path);
    } else {
      // Fallback to regular navigation
      window.location.href = path;
    }
  };

  // If SPA is disabled, render a fallback
  if (!dashboard_spa_enabled) {
    return (
      <div className="dashboard-spa-fallback">
        <p>Dashboard SPA is currently disabled. Please refresh the page to use the server-rendered version.</p>
      </div>
    );
  }

  return (
    <div className="dashboard-spa-layout">
      {/* Persistent Navigation */}
      <Nav
        title="Creator Dashboard"
        helper_host={appDomain}
        helper_session={loggedInUser?.helper_session}
      >
        <div className="dashboard-nav">
          {NAV_ITEMS.map((item) => {
            const isActive = location.pathname === item.path || 
                           (item.path === "/dashboard" && location.pathname.startsWith("/dashboard"));
            
            return (
              <a
                key={item.path}
                href={item.path}
                onClick={(ev) => handleNavClick(ev, item.path)}
                className={`dashboard-nav-item ${isActive ? 'active' : ''}`}
                aria-current={isActive ? 'page' : undefined}
              >
                <Icon name={item.icon} />
                <span>{item.label}</span>
              </a>
            );
          })}
        </div>
        
        {/* User menu and other nav items */}
        <div className="dashboard-nav-footer">
          <a href="/settings/profile">
            <Icon name="user" />
            <span>Settings</span>
          </a>
          <a href="/logout" onClick={(ev) => {
            ev.preventDefault();
            // Handle logout
            window.location.href = "/logout";
          }}>
            <Icon name="sign-out-alt" />
            <span>Logout</span>
          </a>
        </div>
      </Nav>

      {/* Main Content Area */}
      <main className="dashboard-main-content">
        <div className="dashboard-content-wrapper">
          <Outlet />
        </div>
      </main>
    </div>
  );
};
