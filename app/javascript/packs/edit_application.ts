import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import ApplicationEditPage from "$app/components/server-components/Settings/AdvancedPage/EditApplicationPage";

BasePage.initialize();
ReactOnRails.register({ ApplicationEditPage });
