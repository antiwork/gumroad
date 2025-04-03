import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import AudiencePage from "$app/components/server-components/AudiencePage";

BasePage.initialize();

ReactOnRails.default.register({ AudiencePage });
