import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import HelpCenterArticlesIndexPage from "$app/components/server-components/HelpCenter/ArticlesIndexPage";

BasePage.initialize();

ReactOnRails.register({ HelpCenterArticlesIndexPage });
