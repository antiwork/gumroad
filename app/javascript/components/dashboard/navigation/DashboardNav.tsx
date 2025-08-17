import React from "react";
import { NavLink } from "react-router-dom";
import cx from "classnames";

import { Icon } from "$app/components/Icons";
import { useLoggedInUser } from "$app/components/LoggedInUser";

interface NavItem {
  path: string;
  label: string;
  icon: string;
  badge?: number;
  requiredPolicy?: string;
}

interface DashboardNavProps {
  currentPath: string;
}

export const DashboardNav: React.FC<DashboardNavProps> = ({ currentPath }) => {
  const loggedInUser = useLoggedInUser();

  const navItems: NavItem[] = [
    {
      path: "/dashboard",
      label: "Dashboard",
      icon: "house-fill",
    },
    {
      path: "/products",
      label: "Products",
      icon: "bag-fill",
      requiredPolicy: "product",
    },
    {
      path: "/dashboard/sales",
      label: "Sales",
      icon: "graph-up",
      requiredPolicy: "analytics",
    },
    {
      path: "/dashboard/audience",
      label: "Audience",
      icon: "people-fill",
      requiredPolicy: "audience",
    },
    {
      path: "/balance",
      label: "Balance",
      icon: "currency-dollar",
      requiredPolicy: "balance",
    },
    {
      path: "/posts",
      label: "Posts",
      icon: "envelope-fill",
      requiredPolicy: "product_post",
    },
    {
      path: "/dashboard/utm_links",
      label: "UTM Links",
      icon: "link-45deg",
      requiredPolicy: "utm_link",
    },
    {
      path: "/affiliates",
      label: "Affiliates",
      icon: "person-plus-fill",
      requiredPolicy: "affiliate",
    },
    {
      path: "/collaborators",
      label: "Collaborators",
      icon: "people",
      requiredPolicy: "collaborator",
    },
  ];

  const filteredNavItems = navItems.filter(item => {
    if (!item.requiredPolicy) return true;
    
    const policy = loggedInUser?.policies?.[item.requiredPolicy as keyof typeof loggedInUser.policies];
    return policy?.show || policy?.index;
  });

  return (
    <nav className="dashboard-spa-nav">
      <div className="dashboard-spa-nav-header">
        <NavLink to="/dashboard" className="dashboard-spa-nav-logo">
          <Icon name="gumroad-logo" />
          <span>Gumroad</span>
        </NavLink>
      </div>

      <div className="dashboard-spa-nav-items">
        {filteredNavItems.map((item) => (
          <NavLink
            key={item.path}
            to={item.path}
            className={({ isActive }) =>
              cx("dashboard-spa-nav-item", {
                "is-active": isActive || currentPath.startsWith(item.path + "/"),
              })
            }
          >
            <Icon name={item.icon} className="dashboard-spa-nav-icon" />
            <span className="dashboard-spa-nav-label">{item.label}</span>
            {item.badge && (
              <span className="dashboard-spa-nav-badge">{item.badge}</span>
            )}
          </NavLink>
        ))}
      </div>

      <div className="dashboard-spa-nav-footer">
        <NavLink to="/settings" className="dashboard-spa-nav-item">
          <Icon name="gear-fill" className="dashboard-spa-nav-icon" />
          <span className="dashboard-spa-nav-label">Settings</span>
        </NavLink>

        <div className="dashboard-spa-nav-user">
          <img 
            src={loggedInUser?.avatarUrl || ""} 
            alt={loggedInUser?.name || "User"}
            className="dashboard-spa-nav-avatar"
          />
          <div className="dashboard-spa-nav-user-info">
            <div className="dashboard-spa-nav-user-name">
              {loggedInUser?.name || "User"}
            </div>
            <div className="dashboard-spa-nav-user-email">
              {loggedInUser?.email}
            </div>
          </div>
        </div>
      </div>
    </nav>
  );
};