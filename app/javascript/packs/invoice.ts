import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import GenerateInvoiceConfirmationPage from "$app/components/server-components/GenerateInvoiceConfirmationPage";
import GenerateInvoicePage from "$app/components/server-components/GenerateInvoicePage";

BasePage.initialize();

ReactOnRails.register({ GenerateInvoiceConfirmationPage, GenerateInvoicePage });
