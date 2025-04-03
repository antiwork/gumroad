import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import SubscriptionManager from "$app/components/server-components/SubscriptionManager";

BasePage.initialize();
ReactOnRails.register({ SubscriptionManager });
