import { startTrackingForGumroad } from "$app/data/google_analytics";
import { cast } from "$app/utils/cast";
import { installFileDropNavigationGuard } from "$app/utils/preventFileDropNavigation";
import { defaults as requestDefaults } from "$app/utils/request";

const BasePage = {
  initialize() {
    const csrfToken = cast<string>(document.querySelector("meta[name=csrf-token]")?.getAttribute("content"));
    requestDefaults.headers = { "X-CSRF-Token": csrfToken };

    startTrackingForGumroad();
    installFileDropNavigationGuard();
  },
};

export default BasePage;
