import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import SubscribePage from "$app/components/server-components/SubscribePage";

BasePage.initialize();

ReactOnRails.default.register({ SubscribePage });
