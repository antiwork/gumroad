import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import CommunitiesPage from "$app/components/server-components/CommunitiesPage";

BasePage.initialize();
ReactOnRails.register({ CommunitiesPage });
