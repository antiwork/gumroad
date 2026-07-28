import * as React from "react";

import { AssetPreview } from "$app/parsers/product";
import { JWPlayerOptions, createJWPlayer } from "$app/utils/jwPlayer";
import { videoPlayerAspectRatio } from "$app/utils/videoFrame";

import { DEFAULT_IMAGE_WIDTH } from "./";

type Props = {
  cover: AssetPreview;
  dimensions: { width: number; height: number } | null;
  // Whether the frame around this cover has a definite height (i.e. it was shaped to
  // the ACTIVE cover's ratio). `height: 100%` needs that; in an unshaped frame it
  // resolves to auto and, with only an aspect ratio to go on, the box collapses.
  frameIsShaped: boolean;
};

const Video = ({ cover, dimensions, frameIsShaped }: Props) => {
  const id = React.useId();
  // Whether we know the video's real shape. When we do, the box below is sized by that
  // ratio and the player is told the same ratio; when we don't, both keep the old
  // width-derived behaviour.
  const knowsShape =
    frameIsShaped &&
    cover.native_width != null &&
    cover.native_height != null &&
    cover.native_width > 0 &&
    cover.native_height > 0;

  // The player is initialized once when this component renders for the first time.
  // I think it's fine _not_ to react to changes to `cover` prop after the component has been initialized,
  // since a different asset preview will always result in a new instance being instantiated.
  React.useEffect(() => {
    const url = dimensions == null || dimensions.width > DEFAULT_IMAGE_WIDTH ? cover.original_url : cover.url;

    const options: JWPlayerOptions = {
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
    if (knowsShape) {
      // Responsive sizing: JW Player's docs are explicit that `aspectratio` is ignored
      // when the player has a static pixel size, and that `height` should be omitted
      // when `aspectratio` is set. So on this path the player gets a percentage width
      // and the ratio, and no pixel height — it then fills the box we shaped above
      // rather than being a fixed rectangle that overflows a height-capped frame.
      // See https://github.com/antiwork/gumroad-private/issues/1437
      options.width = "100%";
      Object.assign(options, videoPlayerAspectRatio({ width: cover.native_width, height: cover.native_height }));
    } else if (dimensions != null) {
      options.height = `${dimensions.height}px`;
      options.width = `${dimensions.width}px`;
    }

    void createJWPlayer(id, options);
  }, [id]);

  return (
    <div
      onClick={(e) => e.preventDefault()}
      style={
        // When we know the shape, size the box by aspect ratio and let it shrink to fit
        // the frame in BOTH axes. The percentage padding below derives height from width
        // alone, so a portrait video ignored the frame's height cap and spilled out of
        // the bottom of the figure. Videos with no recorded dimensions keep it as before.
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
