import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import CollaboratorsPage from "$app/components/server-components/CollaboratorsPage";

BasePage.initialize();

ReactOnRails.register({ CollaboratorsPage });
