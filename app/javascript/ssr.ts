import "core-js/actual/url";
import "abortcontroller-polyfill/dist/abortcontroller-polyfill-only";
import "whatwg-fetch";
import ReactOnRails from "react-on-rails";

import Alert from "$app/components/server-components/Alert";
import CustomersDownloadPopover from "$app/components/server-components/CustomersPage/DownloadPopover";
import CustomersFilterPopover from "$app/components/server-components/CustomersPage/FilterPopover";
import Nav from "$app/components/server-components/Nav";
import ProductEditPage from "$app/components/server-components/ProductEditPage";
import SupportHeader from "$app/components/server-components/support/Header";
import TaxesCollectionModal from "$app/components/server-components/TaxesCollectionModal";
import CodeSnippet from "$app/components/ui/CodeSnippet";
import { Pill } from "$app/components/ui/Pill";

ReactOnRails.register({
  Alert,
  SupportHeader,
  CodeSnippet,
  CustomersDownloadPopover,
  CustomersFilterPopover,
  Nav,
  Pill,
  ProductEditPage,
  TaxesCollectionModal,
});
