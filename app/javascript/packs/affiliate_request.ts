import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import AffiliateRequestPage from "$app/components/server-components/AffiliateRequestPage";

BasePage.initialize();
ReactOnRails.register({ AffiliateRequestPage });
