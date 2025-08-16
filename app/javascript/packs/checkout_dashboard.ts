import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import DiscountsPage from "$app/components/server-components/CheckoutDashboard/DiscountsPage";
import DiscountCollectionsPage from "$app/components/server-components/CheckoutDashboard/DiscountCollectionsPage";
import FormPage from "$app/components/server-components/CheckoutDashboard/FormPage";
import UpsellsPage from "$app/components/server-components/CheckoutDashboard/UpsellsPage";

BasePage.initialize();

ReactOnRails.register({ DiscountsPage, DiscountCollectionsPage, FormPage, UpsellsPage });
