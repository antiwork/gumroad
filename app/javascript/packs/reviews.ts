import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import ReviewsPage from "$app/components/server-components/ReviewsPage";

BasePage.initialize();
ReactOnRails.register({ ReviewsPage });
