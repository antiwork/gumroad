import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import AdminNav from "$app/components/server-components/Admin/Nav";
import AdminSearchPopover from "$app/components/server-components/Admin/SearchPopover";

BasePage.initialize();
ReactOnRails.register({ AdminNav, AdminSearchPopover });
