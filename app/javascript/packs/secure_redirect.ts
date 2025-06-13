import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import Alert from "$app/components/server-components/Alert";
import SecureRedirectPage from "$app/components/server-components/SecureRedirectPage";

BasePage.initialize();

ReactOnRails.register({ Alert, SecureRedirectPage });
