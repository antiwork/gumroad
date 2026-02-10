import { usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { useDropbox } from "$app/hooks/useDropbox";
import { StandaloneLayout } from "$app/inertia/layout";

import DownloadPageWithContent, {
  DownloadPageWithContentProps,
} from "$app/components/server-components/DownloadPage/WithContent";

type PageProps = DownloadPageWithContentProps & {
  dropbox_api_key: string | null;
};

function DownloadPage() {
  const props = cast<PageProps>(usePage().props);
  const { dropbox_api_key, ...withContentProps } = props;

  useDropbox(dropbox_api_key);

  return <DownloadPageWithContent {...withContentProps} />;
}

DownloadPage.layout = (page: React.ReactNode) => <StandaloneLayout>{page}</StandaloneLayout>;

export default DownloadPage;
