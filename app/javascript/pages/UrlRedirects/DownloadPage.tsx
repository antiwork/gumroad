import { usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import WithContent, { type Props as WithContentProps } from "$app/components/server-components/DownloadPage/WithContent";

function DownloadPage() {
  const props = cast<WithContentProps & { dropbox_api_key: string }>(usePage().props);

  // Load Dropbox script dynamically
  React.useEffect(() => {
    if (document.getElementById("dropboxjs")) return;
    const script = document.createElement("script");
    script.id = "dropboxjs";
    script.src = "https://www.dropbox.com/static/api/2/dropins.js";
    script.dataset.appKey = props.dropbox_api_key;
    document.body.appendChild(script);
  }, [props.dropbox_api_key]);

  return <WithContent {...props} />;
}

DownloadPage.loggedInUserLayout = true;
export default DownloadPage;
