import * as React from "react";

import { AssetPreview } from "$app/parsers/product";
import { JWPlayerOptions, createJWPlayer } from "$app/utils/jwPlayer";
import { videoPlayerAspectRatio } from "$app/utils/videoFrame";

import { DEFAULT_IMAGE_WIDTH } from "./";

type Props = {
  cover: AssetPreview;
  dimensions: { width: number; height: number } | null;
};

const Video = ({ cover, dimensions }: Props) => {
  const id = React.useId();

  // The player is initialized once when this component renders for the first time.
  // I think it's fine _not_ to react to changes to `cover` prop after the component has been initialized,
  // since a different asset preview will always result in a new instance being instantiated.
  React.useEffect(() => {
    const url = dimensions == null || dimensions.width > DEFAULT_IMAGE_WIDTH ? cover.original_url : cover.url;

    const options: JWPlayerOptions = {
      // Tell the player the video's real shape. Without a ratio JW Player assumes
      // 16:9 and letterboxes a phone-filmed portrait video inside our (now
      // correctly shaped) container, which is the bug this fixes; when we have no
      // recorded dimensions nothing is passed and the player keeps its default.
      // See https://github.com/antiwork/gumroad-private/issues/1437
      ...videoPlayerAspectRatio({ width: cover.native_width, height: cover.native_height }),
      // "image" is JW Player's poster frame — the still shown before playback
      // starts. Without it the player idles as a solid black rectangle (the
      // subject of gumroad-private#1074). For uploaded videos the backend
      // extracts a frame with ffmpeg (AssetPreview#video_poster_url); when no
      // poster could be generated this is null and JW Player keeps the old
      // black idle state.
      playlist: [
        { image: cover.thumbnail ?? undefined, sources: [{ file: url, type: cover.filetype?.toLowerCase() }] },
      ],
    };
    if (dimensions != null) {
      options.height = `${dimensions.height}px`;
      options.width = `${dimensions.width}px`;
    }

    void createJWPlayer(id, options);
  }, [id]);

  // When we know the video's real shape, size the box by aspect ratio and let it
  // shrink to fit the frame in BOTH axes. The old percentage padding derives height
  // from width alone, so a portrait video ignored the frame's height cap and spilled
  // out of the bottom of the figure. Videos with no recorded dimensions keep the
  // percentage-padding box exactly as before.
  const knowsShape = cover.native_width != null && cover.native_height != null && cover.native_height > 0;

  return (
    <div
      onClick={(e) => e.preventDefault()}
      style={
        knowsShape
          ? {
              position: "relative",
              aspectRatio: `${cover.native_width} / ${cover.native_height}`,
              // An explicit height with `width: auto` is what makes the box derive its
              // width from the frame's (capped) height. A max-height alone leaves a
              // flex item with an aspect ratio and no definite size in either axis, and
              // it collapses to nothing.
              height: "100%",
              width: "auto",
              maxWidth: "100%",
            }
          : {
              flexGrow: 1,
              position: "relative",
              paddingBottom: `${dimensions === null ? 0 : (dimensions.height * 100) / dimensions.width}%`,
            }
      }
    >
      <div id={id} />
    </div>
  );
};

export { Video };
