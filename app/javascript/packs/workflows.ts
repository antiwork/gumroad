import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import WorkflowsPage from "$app/components/server-components/WorkflowsPage";

BasePage.initialize();

ReactOnRails.register({ WorkflowsPage });
