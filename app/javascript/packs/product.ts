import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import ProfileCoffeePage from "$app/components/server-components/Profile/CoffeePage";

BasePage.initialize();
ReactOnRails.register({
  ProfileCoffeePage,
});
