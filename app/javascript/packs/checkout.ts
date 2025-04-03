import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import CheckoutPage from "$app/components/server-components/CheckoutPage";

BasePage.initialize();

ReactOnRails.register({ CheckoutPage });
