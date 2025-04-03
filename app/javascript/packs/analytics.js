import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import AnalyticsPage from "$app/components/server-components/AnalyticsPage";

BasePage.initialize();

ReactOnRails.default.register({ AnalyticsPage });
