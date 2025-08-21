import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import SupportPortalPage from "$app/components/server-components/SupportPortalPage";

BasePage.initialize();

ReactOnRails.register({ SupportPortalPage });
