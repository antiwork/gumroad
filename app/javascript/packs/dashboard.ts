import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import DashboardPage from "$app/components/server-components/DashboardPage";
import { DashboardSPA } from "$app/components/DashboardSPA";

BasePage.initialize();
ReactOnRails.register({ 
  DashboardPage,
  DashboardSPA 
});
