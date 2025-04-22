import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import DiscountsPage from "$app/components/server-components/CheckoutDashboard/DiscountsPage";
import FormPage from "$app/components/server-components/CheckoutDashboard/FormPage";
import SocialProofWidgetsPage from "$app/components/server-components/CheckoutDashboard/SocialProofWidgetsPage";
import UpsellsPage from "$app/components/server-components/CheckoutDashboard/UpsellsPage";

BasePage.initialize();

ReactOnRails.register({ DiscountsPage, FormPage, UpsellsPage, SocialProofWidgetsPage });
