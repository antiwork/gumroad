import { usePage } from "@inertiajs/react";
import { throttle } from "lodash-es";
import * as React from "react";
import typia from "typia";

import { createConsumptionEvent } from "$app/data/consumption_analytics";
import { trackMediaLocationChanged } from "$app/data/media_location";
import GuidGenerator from "$app/utils/guid_generator";
import { createJWPlayer } from "$app/utils/jwPlayer";

import { TranscodingNoticeModal } from "$app/components/Download/TranscodingNoticeModal";

const FAKE_VIDEO_URL_GUID_FOR_OBFUSCATION = "ef64f2fef0d6c776a337050020423fc0";
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

type StreamProps = {
  playlist: Video[];
  index_to_play: number;
  url_redirect_id: string;
  purchase_id: string | null;
  should_show_transcoding_notice: boolean;
  transcode_on_first_sale: boolean;
};

function Stream() {
  const {
    playlist: initialPlaylist,
    index_to_play,
    url_redirect_id,
    purchase_id,
    should_show_transcoding_notice,
    transcode_on_first_sale,
  } = typia.assert<StreamProps>(usePage().props);

  const containerRef = React.useRef<HTMLDivElement>(null);

  // Deliberately a plain useEffect rather than useRunOnce: this creates a JW Player instance and a
  // throttled tracking callback that both have to be torn down when the component unmounts, and
  // useRunOnce ignores a returned cleanup (it now warns in development when a callback returns one).
  // The effect body still runs only once per mount because it depends on nothing that changes.
  React.useEffect(() => {
    // Player setup is async, so the component can unmount before createJWPlayer resolves. Without
    // this flag the resolved player would be installed into a dead component and never removed,
    // leaving the video element and its listeners attached for the rest of the page's life.
    let isCancelled = false;
    let playerToRemove: jwplayer.JWPlayer | undefined;
    let flushTracking: (() => void) | undefined;

    const createPlayer = async () => {
      if (!containerRef.current) return;

      const playerId = `video-player-${GuidGenerator.generate()}`;
      containerRef.current.id = playerId;

      let lastPlayedId: number | undefined;
      let isInitialSeekDone = false;
      const playlist = initialPlaylist;

      const createdPlayer = await createJWPlayer(playerId, {
        width: "100%",
        height: "100%",
        playlist: playlist.map((video) => ({
          sources: video.sources.map((source) => ({
            file: source.replace(FAKE_VIDEO_URL_GUID_FOR_OBFUSCATION, video.guid),
          })),
          tracks: video.tracks,
          title: video.title,
        })),
      });

      // Unmounted while the player was being set up: remove it immediately rather than wiring up
      // handlers that would fire against a component that no longer exists.
      if (isCancelled) {
        createdPlayer.remove();
        return;
      }
      playerToRemove = createdPlayer;
      const player = createdPlayer;

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
      flushTracking = () => throttledTrackMediaLocation.flush();

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
    };

    void createPlayer();

    return () => {
      isCancelled = true;
      // Flush rather than cancel. lodash throttle defaults to trailing: true, so before this
      // change a pending position write still fired after the buyer navigated away — cancelling
      // it would silently lose up to LOCATION_TRACK_EVENT_DELAY_MS (10s) of watch progress, and
      // the buyer would resume earlier than where they actually stopped. trackMediaLocationChanged
      // is a plain fetch, so it completes independently of this component.
      flushTracking?.();
      // remove() detaches JW Player's own event handlers and DOM, which is what stops the
      // "time" handler from continuing to run against an unmounted component.
      playerToRemove?.remove();
    };
  }, []);

  return (
    <>
      {should_show_transcoding_notice ? (
        <TranscodingNoticeModal transcodeOnFirstSale={transcode_on_first_sale} />
      ) : null}
      <div ref={containerRef} className="absolute h-full w-full"></div>
    </>
  );
}

Stream.loggedInUserLayout = true;
export default Stream;
