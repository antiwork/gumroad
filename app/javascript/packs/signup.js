import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import LoginPage from "$app/components/server-components/LoginPage";
import PasswordResetPage from "$app/components/server-components/PasswordResetPage";
import SignupPage from "$app/components/server-components/SignupPage";
import TwoFactorAuthenticationPage from "$app/components/server-components/TwoFactorAuthenticationPage";

BasePage.initialize();

ReactOnRails.default.register({ SignupPage, LoginPage, TwoFactorAuthenticationPage, PasswordResetPage });
