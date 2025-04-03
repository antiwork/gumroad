import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import LibraryPage from "$app/components/server-components/LibraryPage";

BasePage.initialize();
ReactOnRails.register({ LibraryPage });
