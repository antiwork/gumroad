import cx from "classnames";
import React, { useCallback, useEffect, useRef, useState } from "react";

import { getStreamingUrls } from "$app/data/product_reviews";
import { createJWPlayer } from "$app/utils/jwPlayer";

import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { PlayVideoIcon } from "$app/components/PlayVideoIcon";

function usePlayer(videoId: string, uid: string) {
  const [loading, setLoading] = useState(false);
  const [showPlayer, setShowPlayer] = useState(false);
  const playerRef = useRef<jwplayer.JWPlayer | null>(null);

  const onPlay = useCallback(async () => {
    setLoading(true);

    const { streaming_urls } = await getStreamingUrls(videoId);

    playerRef.current = await createJWPlayer(`${uid}-video`, {
      playlist: [{ sources: streaming_urls.map((file) => ({ file })) }],
    });
    playerRef.current.on("ready", () => {
      setShowPlayer(true);
      playerRef.current?.play();
    });
  }, [videoId, uid]);

  useEffect(
    () => () => {
      if (playerRef.current) {
        playerRef.current.remove();
        playerRef.current = null;
      }
    },
    [],
  );

  return { loading, showPlayer, onPlay, playerId: `${uid}-video` };
}

export const ReviewVideoPlayer = ({ videoId, thumbnail }: { videoId: string; thumbnail?: string | null }) => {
  const uid = React.useId();

  const { loading, showPlayer, onPlay, playerId } = usePlayer(videoId, uid);

  return (
    <div className="relative aspect-video w-full overflow-hidden rounded-sm bg-black">
      <div id={playerId} className={cx({ hidden: !showPlayer })}></div>
      <figure className={cx("relative aspect-video w-full", { hidden: showPlayer })}>
        {thumbnail ? (
          <img src={thumbnail} loading="lazy" className="absolute h-full w-full rounded-t bg-black object-cover" />
        ) : null}
        <button
          className="link absolute top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2"
          onClick={() => void onPlay()}
          aria-label="Watch"
          disabled={loading}
        >
          {loading ? <LoadingSpinner width="3em" /> : <PlayVideoIcon />}
        </button>
      </figure>
    </div>
  );
};
