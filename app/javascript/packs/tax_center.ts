import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import TaxCenterPage from "$app/components/server-components/TaxCenterPage";

BasePage.initialize();
ReactOnRails.register({ TaxCenterPage });
