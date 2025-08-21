import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import HelpCenterArticlesIndexPage from "$app/components/server-components/HelpCenter/ArticlesIndexPage";
import SupportHeader from "$app/components/server-components/support/Header";

BasePage.initialize();

ReactOnRails.register({ HelpCenterArticlesIndexPage, SupportHeader });
