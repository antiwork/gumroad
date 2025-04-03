import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import UtmLinksPage from "$app/components/server-components/UtmLinksPage";

BasePage.initialize();
ReactOnRails.register({ UtmLinksPage });
