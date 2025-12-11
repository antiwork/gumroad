import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import DiscoverWishlistPage from "$app/components/server-components/Discover/WishlistPage";
import ProfileWishlistPage from "$app/components/server-components/Profile/WishlistPage";
import WishlistPage from "$app/components/server-components/WishlistPage";
import WishlistsPage from "$app/components/server-components/WishlistsPage";

BasePage.initialize();
ReactOnRails.register({
  WishlistPage,
  WishlistsPage,
  ProfileWishlistPage,
  DiscoverWishlistPage,
});
