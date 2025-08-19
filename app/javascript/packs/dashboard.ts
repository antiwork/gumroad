import ReactOnRails from "react-on-rails";
import BasePage from "$app/utils/base_page";

// Import SPA component
import DashboardSPA from "$app/components/Dashboard/DashboardSPA";

// Import individual page components for backward compatibility
import DashboardPage from "$app/components/server-components/DashboardPage";

// Initialize base page functionality
BasePage.initialize();

// Register components with ReactOnRails
ReactOnRails.register({
  DashboardSPA,
  DashboardPage, // Keep for backward compatibility
});

export default DashboardSPA;
