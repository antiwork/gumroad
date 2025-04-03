import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import FollowersPage from "$app/components/server-components/FollowersPage";

BasePage.initialize();
ReactOnRails.register({ FollowersPage });
