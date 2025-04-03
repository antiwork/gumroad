import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import ArchivedProductsPage from "$app/components/server-components/ArchivedProductsPage";
import NewProductPage from "$app/components/server-components/NewProductPage";
import ProductsDashboardPage from "$app/components/server-components/ProductsDashboardPage";
import ProductsPage from "$app/components/server-components/ProductsPage";

BasePage.initialize();

ReactOnRails.default.register({ ProductsDashboardPage, ProductsPage, NewProductPage, ArchivedProductsPage });
