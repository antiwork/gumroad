import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import DownloadPageWithContent from "$app/components/server-components/DownloadPage/WithContent";

BasePage.initialize();

ReactOnRails.default.register({ DownloadPageWithContent });
