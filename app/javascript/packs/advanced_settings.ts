import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import AdvancedSettingsPage from "$app/components/server-components/Settings/AdvancedPage";

BasePage.initialize();
ReactOnRails.register({ AdvancedSettingsPage });
