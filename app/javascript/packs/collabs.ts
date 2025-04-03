import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import CollabsPage from "$app/components/server-components/CollabsPage";

BasePage.initialize();

ReactOnRails.register({ CollabsPage });
