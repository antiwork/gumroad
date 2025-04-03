import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import DeveloperWidgetsPage from "$app/components/server-components/Developer/WidgetsPage";

BasePage.initialize();
ReactOnRails.default.register({ DeveloperWidgetsPage });
