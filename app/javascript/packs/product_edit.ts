import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import ProductEditPage from "$app/components/server-components/ProductEditPage";

BasePage.initialize();

ReactOnRails.register({ ProductEditPage });
