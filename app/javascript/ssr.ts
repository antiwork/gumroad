import "core-js/actual/url";
import "abortcontroller-polyfill/dist/abortcontroller-polyfill-only";
import "whatwg-fetch";
import ReactOnRails from "react-on-rails";

import Alert from "$app/components/server-components/Alert";
import BundleEditPage from "$app/components/server-components/BundleEditPage";
import CheckoutPage from "$app/components/server-components/CheckoutPage";
import CommunitiesPage from "$app/components/server-components/CommunitiesPage";
import CustomersDownloadPopover from "$app/components/server-components/CustomersPage/DownloadPopover";
import CustomersFilterPopover from "$app/components/server-components/CustomersPage/FilterPopover";
import Discover from "$app/components/server-components/Discover";
import DiscoverProductPage from "$app/components/server-components/Discover/ProductPage";
import DiscoverWishlistPage from "$app/components/server-components/Discover/WishlistPage";
import DownloadPageWithContent from "$app/components/server-components/DownloadPage/WithContent";
import DownloadPageWithoutContent from "$app/components/server-components/DownloadPage/WithoutContent";
import GenerateInvoiceConfirmationPage from "$app/components/server-components/GenerateInvoiceConfirmationPage";
import GenerateInvoicePage from "$app/components/server-components/GenerateInvoicePage";
import GumroadBlogIndexPage from "$app/components/server-components/GumroadBlog/IndexPage";
import GumroadBlogPostPage from "$app/components/server-components/GumroadBlog/PostPage";
import HelpCenterArticlesIndexPage from "$app/components/server-components/HelpCenter/ArticlesIndexPage";
import Nav from "$app/components/server-components/Nav";
import PdfReaderPage from "$app/components/server-components/PdfReaderPage";
import ProductPage from "$app/components/server-components/Product";
import ProductIframePage from "$app/components/server-components/Product/IframePage";
import ProductEditPage from "$app/components/server-components/ProductEditPage";
import Profile from "$app/components/server-components/Profile";
import ProfileCoffeePage from "$app/components/server-components/Profile/CoffeePage";
import ProfilePostPage from "$app/components/server-components/Profile/PostPage";
import ProfileProductPage from "$app/components/server-components/Profile/ProductPage";
import ProfileWishlistPage from "$app/components/server-components/Profile/WishlistPage";
import DisputeEvidencePage from "$app/components/server-components/Purchase/DisputeEvidencePage";
import PurchaseProductPage from "$app/components/server-components/Purchase/ProductPage";
import SubscribeReviewReminders from "$app/components/server-components/ReviewReminders/SubscribeReviewReminders";
import UnsubscribeReviewReminders from "$app/components/server-components/ReviewReminders/UnsubscribeReviewReminders";
import SecureRedirectPage from "$app/components/server-components/SecureRedirectPage";
import SubscribePage from "$app/components/server-components/SubscribePage";
import SubscriptionManager from "$app/components/server-components/SubscriptionManager";
import SubscriptionManagerMagicLink from "$app/components/server-components/SubscriptionManagerMagicLink";
import SupportHeader from "$app/components/server-components/support/Header";
import TaxesCollectionModal from "$app/components/server-components/TaxesCollectionModal";
import VideoStreamPlayer from "$app/components/server-components/VideoStreamPlayer";
import WishlistPage from "$app/components/server-components/WishlistPage";
import CodeSnippet from "$app/components/ui/CodeSnippet";
import { Pill } from "$app/components/ui/Pill";

ReactOnRails.register({
  Alert,
  HelpCenterArticlesIndexPage,
  SupportHeader,
  BundleEditPage,
  CheckoutPage,
  CodeSnippet,
  CommunitiesPage,
  CustomersDownloadPopover,
  CustomersFilterPopover,
  Discover,
  DiscoverProductPage,
  DiscoverWishlistPage,
  DisputeEvidencePage,
  DownloadPageWithContent,
  DownloadPageWithoutContent,
  GenerateInvoiceConfirmationPage,
  GenerateInvoicePage,
  GumroadBlogIndexPage,
  GumroadBlogPostPage,
  Nav,
  PdfReaderPage,
  Pill,
  ProductEditPage,
  ProductIframePage,
  PurchaseProductPage,
  ProductPage,
  Profile,
  ProfileCoffeePage,
  ProfilePostPage,
  ProfileProductPage,
  ProfileWishlistPage,
  SecureRedirectPage,
  SubscribePage,
  SubscribeReviewReminders,
  UnsubscribeReviewReminders,
  SubscriptionManager,
  SubscriptionManagerMagicLink,
  TaxesCollectionModal,
  VideoStreamPlayer,
  WishlistPage,
});
