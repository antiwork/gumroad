import React from "react";
import { Link } from "react-router-dom";

interface NavItem {
  path: string;
  label: string;
  icon: string;
}

const NAV_ITEMS: NavItem[] = [
  { path: "/dashboard", label: "Dashboard", icon: "home" },
  { path: "/dashboard/sales", label: "Sales Analytics", icon: "chart-line" },
  { path: "/dashboard/audience", label: "Audience", icon: "users" },
  { path: "/dashboard/utm_links", label: "UTM Links", icon: "link" },
];

interface DashboardSidebarProps {
  currentPath: string;
}

export const DashboardSidebar: React.FC<DashboardSidebarProps> = ({ currentPath }) => {
  return (
    <aside
      className="dashboard-sidebar"
      style={{
        position: "fixed",
        top: 0,
        left: 0,
        width: "240px",
        height: "100vh",
        backgroundColor: "#1f2937",
        color: "white",
        padding: "1rem",
        zIndex: 1000
      }}
    >
      {/* Logo/Brand */}
      <div style={{ marginBottom: "2rem", padding: "1rem 0" }}>
        <h2 style={{ margin: 0, fontSize: "1.25rem", fontWeight: "bold" }}>
          Gumroad
        </h2>
      </div>

      {/* Navigation */}
      <nav>
        <ul style={{ listStyle: "none", padding: 0, margin: 0 }}>
          {NAV_ITEMS.map((item) => {
            const isActive = currentPath === item.path;

            return (
              <li key={item.path} style={{ marginBottom: "0.5rem" }}>
                <Link
                  to={item.path}
                  data-testid={`nav-${item.label.toLowerCase().replace(/\s+/g, '-')}`}
                  style={{
                    display: "flex",
                    alignItems: "center",
                    padding: "0.75rem 1rem",
                    borderRadius: "0.5rem",
                    textDecoration: "none",
                    color: isActive ? "#1f2937" : "white",
                    backgroundColor: isActive ? "white" : "transparent",
                    fontWeight: isActive ? "600" : "400",
                    transition: "all 0.2s ease"
                  }}
                  onMouseEnter={(e) => {
                    if (!isActive) {
                      (e.target as HTMLElement).style.backgroundColor = "#374151";
                    }
                  }}
                  onMouseLeave={(e) => {
                    if (!isActive) {
                      (e.target as HTMLElement).style.backgroundColor = "transparent";
                    }
                  }}
                >
                  <span
                    style={{
                      marginRight: "0.75rem",
                      width: "20px",
                      height: "20px",
                      display: "inline-block"
                    }}
                  >
                    📊
                  </span>
                  {item.label}
                </Link>
              </li>
            );
          })}
        </ul>
      </nav>

      {/* Footer */}
      <div style={{
        position: "absolute",
        bottom: "1rem",
        left: "1rem",
        right: "1rem",
        fontSize: "0.875rem",
        color: "#9ca3af"
      }}>
        <p style={{ margin: 0 }}>SPA Mode Active ✨</p>
      </div>
    </aside>
  );
};

export default DashboardSidebar;
