import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import BalancePage from "$app/components/server-components/BalancePage";

BasePage.initialize();
ReactOnRails.register({ BalancePage });
