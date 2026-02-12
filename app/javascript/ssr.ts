import "core-js/actual/url";
import "abortcontroller-polyfill/dist/abortcontroller-polyfill-only";
import "whatwg-fetch";
import ReactOnRails from "react-on-rails";

import Alert from "$app/components/server-components/Alert";
import CustomersDownloadPopover from "$app/components/server-components/CustomersPage/DownloadPopover";
import CustomersFilterPopover from "$app/components/server-components/CustomersPage/FilterPopover";
import Discover from "$app/components/server-components/Discover";
import DownloadPageWithContent from "$app/components/server-components/DownloadPage/WithContent";
import Nav from "$app/components/server-components/Nav";
import ProductEditPage from "$app/components/server-components/ProductEditPage";
import Profile from "$app/components/server-components/Profile";
import SubscribePage from "$app/components/server-components/SubscribePage";
import SupportHeader from "$app/components/server-components/support/Header";
import TaxesCollectionModal from "$app/components/server-components/TaxesCollectionModal";
import VideoStreamPlayer from "$app/components/server-components/VideoStreamPlayer";
import CodeSnippet from "$app/components/ui/CodeSnippet";
import { Pill } from "$app/components/ui/Pill";

ReactOnRails.register({
  Alert,
  SupportHeader,
  CodeSnippet,
  CustomersDownloadPopover,
  CustomersFilterPopover,
  Discover,
  DownloadPageWithContent,
  Nav,
  Pill,
  ProductEditPage,
  Profile,
  SubscribePage,
  TaxesCollectionModal,
  VideoStreamPlayer,
});
