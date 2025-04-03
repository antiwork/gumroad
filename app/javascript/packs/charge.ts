import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import PublicChargePage from "$app/components/server-components/Public/ChargePage";
import PublicLicenseKeyPage from "$app/components/server-components/Public/LicenseKeyPage";

BasePage.initialize();

ReactOnRails.register({ PublicChargePage, PublicLicenseKeyPage });
