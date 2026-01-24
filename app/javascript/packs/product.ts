import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import ProductCartItemsCountPage from "$app/components/server-components/Product/CartItemsCountPage";
import ProfileCoffeePage from "$app/components/server-components/Profile/CoffeePage";
import PurchaseProductPage from "$app/components/server-components/Purchase/ProductPage";

BasePage.initialize();
ReactOnRails.register({
  ProfileCoffeePage,
  PurchaseProductPage,
  ProductCartItemsCountPage,
});
