import React from "react";
import { Link } from "react-router-dom";
import classNames from "classnames";

interface NavigationItem {
  path: string;
  label: string;
  icon: string;
}

interface DashboardSidebarProps {
  currentPath: string;
}

const navigationItems: NavigationItem[] = [
  {
    path: "/dashboard",
    label: "Dashboard",
    icon: "📊"
  },
  {
    path: "/dashboard/sales", 
    label: "Analytics",
    icon: "📈"
  },
  {
    path: "/dashboard/audience",
    label: "Audience", 
    icon: "👥"
  },
  {
    path: "/dashboard/utm_links",
    label: "UTM Links",
    icon: "🔗"
  },
  {
    path: "/dashboard/products",
    label: "Products",
    icon: "📦"
  }
];

export const DashboardSidebar: React.FC<DashboardSidebarProps> = ({ currentPath }) => {
  return (
    <nav className="fixed left-0 top-0 h-full w-64 bg-white border-r border-gray-200 z-10">
      <div className="p-6">
        {/* Logo */}
        <div className="mb-8">
          <h1 className="text-xl font-bold text-gray-900">Gumroad</h1>
        </div>
        
        {/* Navigation */}
        <div className="space-y-2">
          {navigationItems.map((item) => {
            const isActive = currentPath === item.path || 
                           (item.path !== "/dashboard" && currentPath.startsWith(item.path));
            
            return (
              <Link
                key={item.path}
                to={item.path}
                className={classNames(
                  "flex items-center px-4 py-3 rounded-lg text-sm font-medium transition-colors",
                  {
                    "bg-blue-50 text-blue-700 border border-blue-200": isActive,
                    "text-gray-700 hover:bg-gray-50 hover:text-gray-900": !isActive
                  }
                )}
              >
                <span className="mr-3 text-lg">{item.icon}</span>
                {item.label}
              </Link>
            );
          })}
        </div>
      </div>
    </nav>
  );
};
