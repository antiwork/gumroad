import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import BundleEditPage from "$app/components/server-components/BundleEditPage";

BasePage.initialize();

ReactOnRails.register({ BundleEditPage });
