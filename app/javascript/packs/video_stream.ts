import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import VideoStreamPlayer from "$app/components/server-components/VideoStreamPlayer";

BasePage.initialize();

ReactOnRails.register({ VideoStreamPlayer });
