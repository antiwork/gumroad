import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import DownloadPageWithContent from "$app/components/server-components/DownloadPage/WithContent";
import DownloadPageWithoutContent from "$app/components/server-components/DownloadPage/WithoutContent";

BasePage.initialize();

ReactOnRails.default.register({ DownloadPageWithContent, DownloadPageWithoutContent });
