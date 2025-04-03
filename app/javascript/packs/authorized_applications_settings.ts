import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import AuthorizedApplicationsSettingsPage from "$app/components/server-components/Settings/AuthorizedApplicationsPage";

BasePage.initialize();
ReactOnRails.register({ AuthorizedApplicationsSettingsPage });
