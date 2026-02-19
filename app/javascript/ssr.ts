import "core-js/actual/url";
import "abortcontroller-polyfill/dist/abortcontroller-polyfill-only";
import "whatwg-fetch";
import ReactOnRails from "react-on-rails";

import Alert from "$app/components/server-components/Alert";
import Nav from "$app/components/server-components/Nav";
import ProductEditPage from "$app/components/server-components/ProductEditPage";
import CodeSnippet from "$app/components/ui/CodeSnippet";
import { Pill } from "$app/components/ui/Pill";

ReactOnRails.register({
  Alert,
  CodeSnippet,
  Nav,
  Pill,
  ProductEditPage,
});
