import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import AffiliatedPage from "$app/components/server-components/AffiliatedPage";

BasePage.initialize();

ReactOnRails.register({ AffiliatedPage });
