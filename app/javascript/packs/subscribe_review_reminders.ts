import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import SubscribeReviewReminders from "$app/components/server-components/ReviewReminders/SubscribeReviewReminders";

BasePage.initialize();
ReactOnRails.register({ SubscribeReviewReminders });
