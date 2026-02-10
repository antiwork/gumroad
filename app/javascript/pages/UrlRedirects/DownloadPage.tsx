import { usePage } from "@inertiajs/react";
import * as React from "react";
import { createCast } from "ts-safe-cast";

import { WithContent } from "$app/components/server-components/DownloadPage/WithContent";

type PageProps = React.ComponentProps<typeof WithContent>;

const castProps = createCast<PageProps>();

const DownloadPage = () => {
  const props = castProps(usePage().props);

  return (
    <div className="flex min-h-screen flex-col">
      <WithContent {...props} />
    </div>
  );
};

DownloadPage.loggedInUserLayout = true;
export default DownloadPage;
