import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import TaxesCollectionModal from "$app/components/server-components/TaxesCollectionModal";

BasePage.initialize();

ReactOnRails.register({
  TaxesCollectionModal,
});
