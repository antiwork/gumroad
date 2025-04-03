import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import DisputeEvidencePage from "$app/components/server-components/Purchase/DisputeEvidencePage";

BasePage.initialize();
ReactOnRails.register({ DisputeEvidencePage });
