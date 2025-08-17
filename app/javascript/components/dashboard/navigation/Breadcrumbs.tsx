import React from "react";
import { Link, useLocation } from "react-router-dom";
import { Icon } from "$app/components/Icons";

interface BreadcrumbItem {
  label: string;
  path: string;
}

const pathToLabel = (segment: string): string => {
  const labelMap: Record<string, string> = {
    dashboard: "Dashboard",
    products: "Products",
    sales: "Sales",
    audience: "Audience",
    balance: "Balance",
    posts: "Posts",
    utm_links: "UTM Links",
    affiliates: "Affiliates",
    collaborators: "Collaborators",
    new: "New",
    edit: "Edit",
  };

  return labelMap[segment] || segment.charAt(0).toUpperCase() + segment.slice(1);
};

export const Breadcrumbs: React.FC = () => {
  const location = useLocation();
  const pathSegments = location.pathname.split("/").filter(Boolean);

  const breadcrumbs: BreadcrumbItem[] = pathSegments.map((segment, index) => {
    const path = "/" + pathSegments.slice(0, index + 1).join("/");
    return {
      label: pathToLabel(segment),
      path,
    };
  });

  if (breadcrumbs.length === 0) {
    breadcrumbs.push({ label: "Dashboard", path: "/dashboard" });
  }

  return (
    <nav className="dashboard-spa-breadcrumbs" aria-label="Breadcrumb">
      <ol className="dashboard-spa-breadcrumbs-list">
        {breadcrumbs.map((crumb, index) => (
          <li key={crumb.path} className="dashboard-spa-breadcrumbs-item">
            {index > 0 && (
              <Icon name="chevron-right" className="dashboard-spa-breadcrumbs-separator" />
            )}
            {index === breadcrumbs.length - 1 ? (
              <span className="dashboard-spa-breadcrumbs-current" aria-current="page">
                {crumb.label}
              </span>
            ) : (
              <Link to={crumb.path} className="dashboard-spa-breadcrumbs-link">
                {crumb.label}
              </Link>
            )}
          </li>
        ))}
      </ol>
    </nav>
  );
};