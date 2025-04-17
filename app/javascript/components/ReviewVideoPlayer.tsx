import React from "react";

import { createJWPlayer } from "$app/utils/jwPlayer";

import { PlayVideoIcon } from "$app/components/PlayVideoIcon";

export const ReviewVideoPlayer = ({ sources, thumbnail }: { sources: string[]; thumbnail?: string }) => {
  const uid = React.useId();

  const player = React.useRef<jwplayer.JWPlayer | null>(null);
  const [showPlayer, setShowPlayer] = React.useState(false);

  React.useEffect(() => {
    if (!showPlayer) return;

    void createJWPlayer(`${uid}-video`, {
      playlist: [
        {
          sources: sources.map((source) => ({ file: source })),
        },
      ],
    }).then((jwPlayer) => {
      player.current = jwPlayer;
      jwPlayer
        .on("ready", () => {
          if (player.current?.getState() === "playing") {
            player.current.play();
          }
        })
        .on("complete", () => {
          setShowPlayer(false);
          player.current = null;
        });
    });
  }, [showPlayer]);

  const playerElement = () => <div id={`${uid}-video`}></div>;
  const thumbnailElement = () => (
    <figure className="relative aspect-video w-full">
      <img src={thumbnail} className="absolute h-full w-full rounded-t bg-black object-cover" />
      <button
        className="link absolute left-1/2 top-1/2 -translate-x-1/2 -translate-y-1/2"
        onClick={() => setShowPlayer(true)}
        aria-label="Watch"
      >
        <PlayVideoIcon />
      </button>
    </figure>
  );

  return <div className="w-full overflow-hidden rounded">{showPlayer ? playerElement() : thumbnailElement()}</div>;
};
