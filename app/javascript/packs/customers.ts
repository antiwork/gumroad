import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import AudienceCustomersPage from "$app/components/server-components/Audience/CustomersPage";

BasePage.initialize();

ReactOnRails.register({ AudienceCustomersPage });
