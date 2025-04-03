import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import UnsubscribeReviewReminders from "$app/components/server-components/ReviewReminders/UnsubscribeReviewReminders";

BasePage.initialize();
ReactOnRails.register({ UnsubscribeReviewReminders });
