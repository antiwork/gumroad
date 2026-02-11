import "core-js/actual/url";
import "abortcontroller-polyfill/dist/abortcontroller-polyfill-only";
import "whatwg-fetch";
import ReactOnRails from "react-on-rails";

import Alert from "$app/components/server-components/Alert";
import CommunitiesPage from "$app/components/server-components/CommunitiesPage";
import CustomersDownloadPopover from "$app/components/server-components/CustomersPage/DownloadPopover";
import CustomersFilterPopover from "$app/components/server-components/CustomersPage/FilterPopover";
import Discover from "$app/components/server-components/Discover";
import DiscoverProductPage from "$app/components/server-components/Discover/ProductPage";
import DownloadPageWithContent from "$app/components/server-components/DownloadPage/WithContent";
import GenerateInvoiceConfirmationPage from "$app/components/server-components/GenerateInvoiceConfirmationPage";
import GenerateInvoicePage from "$app/components/server-components/GenerateInvoicePage";
import Nav from "$app/components/server-components/Nav";
import ProductPage from "$app/components/server-components/Product";
import ProductIframePage from "$app/components/server-components/Product/IframePage";
import ProductEditPage from "$app/components/server-components/ProductEditPage";
import Profile from "$app/components/server-components/Profile";
import ProfileProductPage from "$app/components/server-components/Profile/ProductPage";
import SubscribePage from "$app/components/server-components/SubscribePage";
import SubscriptionManagerMagicLink from "$app/components/server-components/SubscriptionManagerMagicLink";
import SupportHeader from "$app/components/server-components/support/Header";
import TaxesCollectionModal from "$app/components/server-components/TaxesCollectionModal";
import VideoStreamPlayer from "$app/components/server-components/VideoStreamPlayer";
import CodeSnippet from "$app/components/ui/CodeSnippet";
import { Pill } from "$app/components/ui/Pill";

ReactOnRails.register({
  Alert,
  SupportHeader,
  CodeSnippet,
  CommunitiesPage,
  CustomersDownloadPopover,
  CustomersFilterPopover,
  Discover,
  DiscoverProductPage,
  DownloadPageWithContent,
  GenerateInvoiceConfirmationPage,
  GenerateInvoicePage,
  Nav,
  Pill,
  ProductEditPage,
  ProductIframePage,
  ProductPage,
  Profile,
  ProfileProductPage,
  SubscribePage,
  SubscriptionManagerMagicLink,
  TaxesCollectionModal,
  VideoStreamPlayer,
});
