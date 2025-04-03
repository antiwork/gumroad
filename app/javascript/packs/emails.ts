import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import EmailsPage from "$app/components/server-components/EmailsPage";

BasePage.initialize();

ReactOnRails.register({ EmailsPage });
