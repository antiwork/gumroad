import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import DownloadPageWithoutContent from "$app/components/server-components/DownloadPage/WithoutContent";

BasePage.initialize();

ReactOnRails.default.register({ DownloadPageWithoutContent });
