import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import MainSettingsPage from "$app/components/server-components/Settings/MainPage";
import TeamSettingsPage from "$app/components/server-components/Settings/TeamPage";
import ThirdPartyAnalyticsSettingsPage from "$app/components/server-components/Settings/ThirdPartyAnalyticsPage";

BasePage.initialize();

ReactOnRails.register({ MainSettingsPage, TeamSettingsPage, ThirdPartyAnalyticsSettingsPage });
