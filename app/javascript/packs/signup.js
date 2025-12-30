import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import PasswordResetPage from "$app/components/server-components/PasswordResetPage";
import TwoFactorAuthenticationPage from "$app/components/server-components/TwoFactorAuthenticationPage";

BasePage.initialize();

ReactOnRails.default.register({ TwoFactorAuthenticationPage, PasswordResetPage });
