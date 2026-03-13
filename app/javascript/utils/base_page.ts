import { cast } from "ts-safe-cast";

import { startTrackingForGumroad } from "$app/data/google_analytics";
import { defaults as requestDefaults } from "$app/utils/request";

const BasePage = {
  initialize() {
    const csrfToken = cast<string>($("meta[name=csrf-token]").attr("content"));
    $(document).ajaxSend((_, xhr) => {
      // add CSRF header to all AJAX requests
      xhr.setRequestHeader("X-CSRF-Token", csrfToken);
    });
    requestDefaults.headers = { "X-CSRF-Token": csrfToken };

    startTrackingForGumroad();
  },
};

export default BasePage;
