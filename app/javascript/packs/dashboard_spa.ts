import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";
import DashboardSPA from "$app/components/server-components/DashboardSPA";

BasePage.initialize();
ReactOnRails.register({ DashboardSPA });
