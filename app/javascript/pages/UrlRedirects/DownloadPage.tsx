import { usePoll, usePage } from "@inertiajs/react";
import * as React from "react";
import typia from "typia";

import { useDropbox } from "$app/hooks/useDropbox";
import FileUtils from "$app/utils/file";
import { MEDIA_PLAYBACK_EVENT, isMediaPlaybackEvent } from "$app/utils/media_playback";

import { FileItem } from "$app/components/Download/FileList";
import { LayoutProps } from "$app/components/DownloadPage/Layout";
import { ContentProps, SellerAnalyticsProps, WithContent } from "$app/components/DownloadPage/WithContent";

type PageProps = LayoutProps & {
  content: ContentProps;
  product_has_third_party_analytics: boolean | null;
  seller_analytics: SellerAnalyticsProps | null;
  audio_durations?: Record<string, FileItem["duration"]>;
  latest_media_locations?: Record<string, FileItem["latest_media_location"]>;
  dropbox_api_key: string | null;
};

function DownloadPage() {
  const props = typia.assert<PageProps>(usePage().props);
  const { content, dropbox_api_key, audio_durations, latest_media_locations } = props;

  useDropbox(dropbox_api_key);

  const contentFiles = content.content_items.filter((item): item is FileItem => item.type === "file");
  const hasRichContent = content.rich_content_pages !== null;

  const hasUnprocessedAudio =
    hasRichContent && contentFiles.some((file) => FileUtils.isAudioExtension(file.extension) && file.duration === null);

  const hasMediaFiles = hasRichContent && contentFiles.length > 0;

  // The ids of the players currently playing. Tracked as a set rather than a single flag
  // because a content page can embed several videos, and one of them pausing must not cancel
  // out another that is still playing. See app/javascript/utils/media_playback.ts for why
  // playback pauses the position poll.
  const [playingPlayerIds, setPlayingPlayerIds] = React.useState<ReadonlySet<string>>(new Set());
  const isMediaPlaying = playingPlayerIds.size > 0;
  React.useEffect(() => {
    const handlePlaybackChange = (event: Event) => {
      if (!isMediaPlaybackEvent(event)) return;
      const { playerId, isPlaying } = event.detail;
      setPlayingPlayerIds((current) => {
        if (current.has(playerId) === isPlaying) return current;
        const next = new Set(current);
        if (isPlaying) next.add(playerId);
        else next.delete(playerId);
        return next;
      });
    };
    window.addEventListener(MEDIA_PLAYBACK_EVENT, handlePlaybackChange);
    return () => window.removeEventListener(MEDIA_PLAYBACK_EVENT, handlePlaybackChange);
  }, []);

  const audioDurationsPoll = usePoll(5_000, { only: ["audio_durations"] }, { autoStart: false });
  const mediaLocationsPoll = usePoll(10_000, { only: ["latest_media_locations"] }, { autoStart: false });

  React.useEffect(() => {
    if (hasUnprocessedAudio) audioDurationsPoll.start();
    else audioDurationsPoll.stop();
  }, [hasUnprocessedAudio]);

  React.useEffect(() => {
    if (hasMediaFiles && !isMediaPlaying) mediaLocationsPoll.start();
    else mediaLocationsPoll.stop();
  }, [hasMediaFiles, isMediaPlaying]);

  return (
    <div className="flex min-h-screen flex-col">
      <WithContent {...props} audio_durations={audio_durations} latest_media_locations={latest_media_locations} />
    </div>
  );
}

DownloadPage.loggedInUserLayout = true;
export default DownloadPage;
