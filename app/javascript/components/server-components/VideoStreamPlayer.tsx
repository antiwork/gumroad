import throttle from "lodash/throttle";
import * as React from "react";
import { cast, createCast } from "ts-safe-cast";

import { createConsumptionEvent } from "$app/data/consumption_analytics";
import { trackMediaLocationChanged } from "$app/data/media_location";
import GuidGenerator from "$app/utils/guid_generator";
import { createJWPlayer } from "$app/utils/jwPlayer";
import { register } from "$app/utils/serverComponentUtil";
import { assertResponseError, request, ResponseError } from "$app/utils/request";

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
      const playlist = initialPlaylist;

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

      let lastKnownPosition = 0;
      let lastPauseAtMs: number | null = null;

      const getCurrentVideoFile = () => playlist[player.getPlaylistIndex()];

      const extractTokenFromPath = (): string | null => {
        const match = window.location.pathname.match(/\/url_redirects\/([^/]+)/);
        return match ? match[1] : null;
      };

      const refreshCurrentItemSources = async () => {
        const current = getCurrentVideoFile();
        if (!current) return;
        try {
          const token = extractTokenFromPath();
          if (!token) return;
          const response = await request({
            url: Routes.url_redirect_media_urls_path(token, { params: { file_ids: [current.external_id] } }),
            method: "GET",
            accept: "json",
          });
          if (!response.ok) throw new ResponseError();
          const urls = cast<Record<string, string[]>>(await response.json());
          const sources = (urls[current.external_id] || []).map((u) => ({ file: u }));
          if (sources.length === 0) return;

          player.load([{ sources, tracks: current.tracks, title: current.title }]);

          const targetTime = Math.max(0, lastKnownPosition - 1);
          player.on("loaded", () => {
            if (targetTime > 0) player.seek(targetTime);
            player.play();
          });
        } catch (e) {
          assertResponseError(e);
        }
      };

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
        lastKnownPosition = ev.offset;
      });

      player.on("time", (ev) => {
        throttledTrackMediaLocation(ev.position);
        updateLocalMediaLocation(ev.position, ev.duration);
        lastKnownPosition = ev.position;
      });

      player.on("complete", () => {
        throttledTrackMediaLocation.cancel();
        const videoFile = playlist[player.getPlaylistIndex()];
        if (!videoFile) return;
        trackMediaLocation(videoFile.content_length === null ? player.getDuration() : videoFile.content_length);
        updateLocalMediaLocation(player.getDuration(), player.getDuration());
      });

      player.on("play", () => {
        const itemId = player.getPlaylistIndex();
        const videoFile = playlist[itemId];
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
        lastPauseAtMs = null;
      });

      player.on("visualQuality", () => {
        if (isInitialSeekDone && lastPlayedId === player.getPlaylistIndex()) return;
        const videoFile = playlist[player.getPlaylistIndex()];
        if (
          videoFile?.latest_media_location != null &&
          videoFile.latest_media_location.location !== videoFile.content_length
        ) {
          player.seek(videoFile.latest_media_location.location);
        }
        isInitialSeekDone = true;
      });

      player.on("pause", () => {
        lastPauseAtMs = Date.now();
      });
      player.on("idle", () => {
        lastPauseAtMs = Date.now();
      });

      player.on("error", () => {
        void refreshCurrentItemSources();
      });
      player.on("playAttemptFailed", () => {
        void refreshCurrentItemSources();
      });

      const onVisibilityChange = () => {
        if (document.visibilityState === "visible" && lastPauseAtMs != null) {
          const pausedForMs = Date.now() - lastPauseAtMs;
          if (pausedForMs > 5 * 60 * 1000) {
            void refreshCurrentItemSources();
          }
        }
      };
      document.addEventListener("visibilitychange", onVisibilityChange);

      let bufferTimeout: ReturnType<typeof setTimeout> | null = null;
      const clearBufferTimeout = () => {
        if (bufferTimeout) {
          clearTimeout(bufferTimeout);
          bufferTimeout = null;
        }
      };
      player.on("buffer", () => {
        clearBufferTimeout();
        bufferTimeout = setTimeout(() => {
          void refreshCurrentItemSources();
        }, 10 * 1000);
      });
      player.on("playing", clearBufferTimeout);
      player.on("complete", clearBufferTimeout);

      const cleanup = () => {
        document.removeEventListener("visibilitychange", onVisibilityChange);
        clearBufferTimeout();
      };
      // eslint-disable-next-line @typescript-eslint/no-misused-promises
      window.addEventListener("beforeunload", cleanup);
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
