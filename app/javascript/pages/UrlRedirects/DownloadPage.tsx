import { router, usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { useDropbox } from "$app/hooks/useDropbox";
import { StandaloneLayout } from "$app/inertia/layout";
import FileUtils from "$app/utils/file";

import DownloadPageWithContent, {
  DownloadPageWithContentProps,
} from "$app/components/server-components/DownloadPage/WithContent";
import { FileItem } from "$app/components/Download/FileList";

const AUDIO_DURATIONS_POLL_INTERVAL_MS = 5_000;
const LATEST_MEDIA_LOCATIONS_POLL_INTERVAL_MS = 10_000;
const MAX_AUDIO_IDS_PER_FETCH = 25;

type PageProps = DownloadPageWithContentProps & {
  dropbox_api_key: string | null;
};

function DownloadPage() {
  const props = cast<PageProps>(usePage().props);
  const { dropbox_api_key, ...withContentProps } = props;
  const contentFiles = React.useMemo(
    () => props.content.content_items.filter((item): item is FileItem => item.type === "file"),
    [props.content.content_items],
  );
  const hasRichContent = props.content.rich_content_pages !== null;
  const audioDurationsToFetch = React.useMemo(() => {
    if (!hasRichContent || !props.is_mobile_app_web_view) return [];
    return contentFiles
      .flatMap((file) => {
        const duration = props.audio_durations?.[file.id] ?? file.duration;
        return FileUtils.isAudioExtension(file.extension) && duration === null ? [file.id] : [];
      })
      .slice(0, MAX_AUDIO_IDS_PER_FETCH);
  }, [hasRichContent, props.is_mobile_app_web_view, contentFiles, props.audio_durations]);

  const shouldPollLatestMediaLocations =
    hasRichContent && contentFiles.length > 0 && props.purchase !== null && props.installment === null;

  useDropbox(dropbox_api_key);
  React.useEffect(() => {
    if (audioDurationsToFetch.length === 0) return;

    const audioDurationsPoll = router.poll(
      AUDIO_DURATIONS_POLL_INTERVAL_MS,
      {
        only: ["audio_durations"],
        data: { file_ids: audioDurationsToFetch },
        preserveUrl: true,
      },
      { autoStart: true, keepAlive: true },
    );

    return () => audioDurationsPoll.stop();
  }, [audioDurationsToFetch.join(",")]);

  React.useEffect(() => {
    if (!shouldPollLatestMediaLocations) return;

    const latestMediaLocationsPoll = router.poll(
      LATEST_MEDIA_LOCATIONS_POLL_INTERVAL_MS,
      {
        only: ["latest_media_locations"],
        preserveUrl: true,
      },
      { autoStart: true, keepAlive: true },
    );

    return () => latestMediaLocationsPoll.stop();
  }, [shouldPollLatestMediaLocations]);

  return <DownloadPageWithContent {...withContentProps} />;
}

DownloadPage.layout = (page: React.ReactNode) => <StandaloneLayout>{page}</StandaloneLayout>;

export default DownloadPage;
