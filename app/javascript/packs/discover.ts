import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import Discover from "$app/components/server-components/Discover";

BasePage.initialize();
ReactOnRails.register({ Discover });
