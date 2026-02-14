import { usePoll, usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { useDropbox } from "$app/hooks/useDropbox";
import FileUtils from "$app/utils/file";

import { FileItem } from "$app/components/Download/FileList";
import { LayoutProps } from "$app/components/DownloadPage/Layout";
import { ContentProps, WithContent } from "$app/components/DownloadPage/WithContent";

type PageProps = LayoutProps & {
  content: ContentProps;
  product_has_third_party_analytics: boolean | null;
  audio_durations?: Record<string, FileItem["duration"]>;
  latest_media_locations?: Record<string, FileItem["latest_media_location"]>;
  dropbox_api_key: string | null;
};

function DownloadPage() {
  const props = cast<PageProps>(usePage().props);
  const { content, dropbox_api_key, audio_durations, latest_media_locations } = props;

  useDropbox(dropbox_api_key);

  const contentFiles = content.content_items.filter((item): item is FileItem => item.type === "file");
  const hasRichContent = content.rich_content_pages !== null;

  const hasUnprocessedAudio =
    hasRichContent && contentFiles.some((file) => FileUtils.isAudioExtension(file.extension) && file.duration === null);

  const hasMediaFiles = hasRichContent && contentFiles.length > 0;

  const audioDurationsPoll = usePoll(5_000, { only: ["audio_durations"] }, { autoStart: false });
  const mediaLocationsPoll = usePoll(10_000, { only: ["latest_media_locations"] }, { autoStart: false });

  React.useEffect(() => {
    if (hasUnprocessedAudio) audioDurationsPoll.start();
    else audioDurationsPoll.stop();
  }, [hasUnprocessedAudio]);

  React.useEffect(() => {
    if (hasMediaFiles) mediaLocationsPoll.start();
    else mediaLocationsPoll.stop();
  }, [hasMediaFiles]);

  return (
    <div className="flex min-h-screen flex-col">
      <WithContent {...props} audio_durations={audio_durations} latest_media_locations={latest_media_locations} />
    </div>
  );
}

DownloadPage.loggedInUserLayout = true;
export default DownloadPage;
