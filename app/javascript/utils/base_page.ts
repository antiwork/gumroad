import typia from "typia";

import { startTrackingForGumroad } from "$app/data/google_analytics";
import { installFileDropNavigationGuard } from "$app/utils/preventFileDropNavigation";
import { defaults as requestDefaults } from "$app/utils/request";

const BasePage = {
  initialize() {
    const csrfToken = typia.assert<string>(document.querySelector("meta[name=csrf-token]")?.getAttribute("content"));
    requestDefaults.headers = { "X-CSRF-Token": csrfToken };

    startTrackingForGumroad();
    installFileDropNavigationGuard();
  },
};

export default BasePage;
