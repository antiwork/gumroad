import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import SubscriptionManagerMagicLink from "$app/components/server-components/SubscriptionManagerMagicLink";

BasePage.initialize();

ReactOnRails.register({
  SubscriptionManagerMagicLink,
});
