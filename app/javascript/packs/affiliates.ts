import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import AffiliatesPage from "$app/components/server-components/AffiliatesPage";

BasePage.initialize();

ReactOnRails.register({ AffiliatesPage });
