import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import Profile from "$app/components/server-components/Profile";

BasePage.initialize();

ReactOnRails.default.register({ Profile });
