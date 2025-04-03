import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import DiscoverWishlistPage from "$app/components/server-components/Discover/WishlistPage";
import ProfileWishlistPage from "$app/components/server-components/Profile/WishlistPage";
import WishlistPage from "$app/components/server-components/WishlistPage";
import WishlistsFollowingPage from "$app/components/server-components/WishlistsFollowingPage";
import WishlistsPage from "$app/components/server-components/WishlistsPage";

BasePage.initialize();
ReactOnRails.register({
  WishlistPage,
  WishlistsFollowingPage,
  WishlistsPage,
  ProfileWishlistPage,
  DiscoverWishlistPage,
});
