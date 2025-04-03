import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import PasswordSettingsPage from "$app/components/server-components/Settings/PasswordPage";

BasePage.initialize();
ReactOnRails.default.register({ PasswordSettingsPage });
