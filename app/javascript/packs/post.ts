import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import ProfilePostPage from "$app/components/server-components/Profile/PostPage";

BasePage.initialize();
ReactOnRails.register({ ProfilePostPage });
