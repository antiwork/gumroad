import React from "react";
import { useLocation } from "react-router-dom";

const getPageTitle = (pathname: string): string => {
  if (pathname === "/dashboard" || pathname === "/") return "Dashboard";
  if (pathname.includes("/sales")) return "Analytics";
  if (pathname.includes("/audience")) return "Audience";
  if (pathname.includes("/utm_links")) return "UTM Links";
  if (pathname.includes("/products")) return "Products";
  return "Dashboard";
};

export const DashboardHeader: React.FC = () => {
  const location = useLocation();
  const pageTitle = getPageTitle(location.pathname);

  return (
    <header className="border-gray-200 ml-64 border-b bg-white px-6 py-4">
      <div className="flex items-center justify-between">
        {/* Page Title */}
        <div>
          <h1 className="text-gray-900 text-2xl font-bold">{pageTitle}</h1>
          <p className="text-gray-500 mt-1 text-sm">
            {pageTitle === "Dashboard" && "Welcome to your creator dashboard"}
            {pageTitle === "Analytics" && "Track your sales and performance"}
            {pageTitle === "Audience" && "Understand your customers"}
            {pageTitle === "UTM Links" && "Manage your marketing links"}
            {pageTitle === "Products" && "Manage your products"}
          </p>
        </div>

        {/* Header Actions */}
        <div className="flex items-center space-x-4">
          {/* Add any header actions here */}
          <button className="rounded-lg bg-blue-600 px-4 py-2 text-white transition-colors hover:bg-blue-700">
            New Product
          </button>
        </div>
      </div>
    </header>
  );
};
