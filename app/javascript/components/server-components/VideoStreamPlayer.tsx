import throttle from "lodash/throttle";
import * as React from "react";
import { createCast } from "ts-safe-cast";

import { createConsumptionEvent } from "$app/data/consumption_analytics";
import { trackMediaLocationChanged } from "$app/data/media_location";
import GuidGenerator from "$app/utils/guid_generator";
import { createJWPlayer } from "$app/utils/jwPlayer";
import { register } from "$app/utils/serverComponentUtil";

import { TranscodingNoticeModal } from "$app/components/Download/TranscodingNoticeModal";
import { useRunOnce } from "$app/components/useRunOnce";

const LOCATION_TRACK_EVENT_DELAY_MS = 10_000;

type SubtitleFile = {
  file: string;
  label: string;
  kind: "captions";
};

type Video = {
  sources: string[];
  guid: string;
  title: string;
  tracks: SubtitleFile[];
  external_id: string;
  latest_media_location: { location: number } | null;
  content_length: number | null;
};

const fakeVideoUrlGuidForObfuscation = "ef64f2fef0d6c776a337050020423fc0";

export const VideoStreamPlayer = ({
  playlist: initialPlaylist,
  index_to_play,
  url_redirect_id,
  purchase_id,
  should_show_transcoding_notice,
  transcode_on_first_sale,
}: {
  playlist: Video[];
  index_to_play: number;
  url_redirect_id: string;
  purchase_id: string | null;
  should_show_transcoding_notice: boolean;
  transcode_on_first_sale: boolean;
}) => {
  const containerRef = React.useRef<HTMLDivElement>(null);

  useRunOnce(() => {
    const createPlayer = async () => {
      if (!containerRef.current) return;

      const playerId = `video-player-${GuidGenerator.generate()}`;
      containerRef.current.id = playerId;

      let lastPlayedId: number | undefined;
      let isInitialSeekDone = false;
      let lastPauseTime: number | null = null;
      let isSeekingFromPause = false;
      const playlist = initialPlaylist;
      const LONG_PAUSE_THRESHOLD = 5 * 60 * 1000; // 5 minutes in ms

      const player = await createJWPlayer(playerId, {
        width: "100%",
        height: "100%",
        playlist: playlist.map((video) => ({
          sources: video.sources.map((source) => ({
            file: source.replace(fakeVideoUrlGuidForObfuscation, video.guid),
          })),
          tracks: video.tracks,
          title: video.title,
        })),
      });

      const updateLocalMediaLocation = (position: number, duration: number) => {
        const videoFile = playlist[player.getPlaylistIndex()];
        if (videoFile && isInitialSeekDone && lastPlayedId === player.getPlaylistIndex()) {
          const location = position === duration ? 0 : position;
          if (videoFile.latest_media_location == null) videoFile.latest_media_location = { location };
          else videoFile.latest_media_location.location = location;
        }
      };

      const trackMediaLocation = (position: number) => {
        if (purchase_id != null) {
          const videoFile = playlist[player.getPlaylistIndex()];
          if (!videoFile) return;
          void trackMediaLocationChanged({
            urlRedirectId: url_redirect_id,
            productFileId: videoFile.external_id,
            purchaseId: purchase_id,
            location:
              videoFile.content_length != null && position > videoFile.content_length
                ? videoFile.content_length
                : position,
          });
        }
      };

      const throttledTrackMediaLocation = throttle(trackMediaLocation, LOCATION_TRACK_EVENT_DELAY_MS);

      player.on("ready", () => {
        player.playlistItem(index_to_play);
      });

      player.on("seek", (ev) => {
        trackMediaLocation(ev.offset);
        updateLocalMediaLocation(ev.offset, player.getDuration());
      });

      player.on("time", (ev) => {
        throttledTrackMediaLocation(ev.position);
        updateLocalMediaLocation(ev.position, ev.duration);
      });

      player.on("complete", () => {
        throttledTrackMediaLocation.cancel();
        const videoFile = playlist[player.getPlaylistIndex()];
        if (!videoFile) return;
        trackMediaLocation(videoFile.content_length === null ? player.getDuration() : videoFile.content_length);
        updateLocalMediaLocation(player.getDuration(), player.getDuration());
      });

      player.on("pause", () => {
        lastPauseTime = Date.now();
      });

      player.on("play", () => {
        const itemId = player.getPlaylistIndex();
        const videoFile = playlist[itemId];
        
        // Check if resuming from a long pause
        if (lastPauseTime && Date.now() - lastPauseTime > LONG_PAUSE_THRESHOLD) {
          isSeekingFromPause = true;
          const currentPosition = player.getPosition();
          
          // If position is at the beginning, seek to last saved position
          if (currentPosition < 1 && videoFile?.latest_media_location?.location) {
            player.seek(videoFile.latest_media_location.location);
          }
        }
        lastPauseTime = null;
        
        if (videoFile !== undefined && lastPlayedId !== itemId) {
          void createConsumptionEvent({
            eventType: "watch",
            urlRedirectId: url_redirect_id,
            productFileId: videoFile.external_id,
            purchaseId: purchase_id,
          });
          lastPlayedId = itemId;
          isInitialSeekDone = false;
        }
      });

      player.on("visualQuality", () => {
        if (isInitialSeekDone && lastPlayedId === player.getPlaylistIndex() && !isSeekingFromPause) return;
        
        const videoFile = playlist[player.getPlaylistIndex()];
        if (
          videoFile?.latest_media_location != null &&
          videoFile.latest_media_location.location !== videoFile.content_length &&
          !isSeekingFromPause // Don't seek if we're already seeking from pause
        ) {
          player.seek(videoFile.latest_media_location.location);
        }
        
        isInitialSeekDone = true;
        isSeekingFromPause = false;
      });

      // Handle stream errors that might occur after long pauses
      player.on("error", (error) => {
        console.error("JWPlayer error:", error);
        
        // If error occurs, try to resume from saved position
        const videoFile = playlist[player.getPlaylistIndex()];
        if (videoFile?.latest_media_location?.location) {
          // Reload the player at the saved position
          player.load(playlist.map((video) => ({
            sources: video.sources.map((source) => ({
              file: source.replace(fakeVideoUrlGuidForObfuscation, video.guid),
            })),
            tracks: video.tracks,
            title: video.title,
          })));
          
          player.once("ready", () => {
            player.playlistItem(player.getPlaylistIndex());
            player.seek(videoFile.latest_media_location!.location);
          });
        }
      });
    };

    void createPlayer();
  });

  return (
    <>
      {should_show_transcoding_notice ? (
        <TranscodingNoticeModal transcodeOnFirstSale={transcode_on_first_sale} />
      ) : null}
      <div ref={containerRef} className="absolute h-full w-full"></div>
    </>
  );
};

export default register({ component: VideoStreamPlayer, propParser: createCast() });
