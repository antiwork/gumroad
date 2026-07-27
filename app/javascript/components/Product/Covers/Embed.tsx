import * as React from "react";

import { AssetPreview } from "$app/parsers/product";

import { DEFAULT_IMAGE_WIDTH } from "./";

type Props = { cover: AssetPreview; dimensions: { width: number; height: number } | null };
const Embed = ({ cover, dimensions }: Props) => {
  const iframeRef = React.useRef<null | HTMLIFrameElement>(null);

  // Same shape as Covers/Video: when the embed's real dimensions are known, size the
  // box by aspect ratio so it shrinks to fit a height-capped frame. The percentage
  // padding below derives height from width alone, so a portrait embed would overflow
  // the frame and be cropped top and bottom. Embeds with no recorded dimensions keep
  // the percentage box exactly as before.
  const knowsShape = cover.native_width != null && cover.native_height != null && cover.native_height > 0;

  return (
    <div
      style={
        knowsShape
          ? {
              position: "relative",
              aspectRatio: `${cover.native_width} / ${cover.native_height}`,
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
      {/* eslint-disable-next-line react/iframe-missing-sandbox */}
      <iframe
        key={cover.url}
        ref={iframeRef}
        width={dimensions?.width}
        height={dimensions?.height}
        src={dimensions == null || dimensions.width > DEFAULT_IMAGE_WIDTH ? cover.original_url : cover.url}
        allowFullScreen
        frameBorder="0"
        sandbox="allow-scripts allow-same-origin allow-popups"
        style={{ width: "100%", height: "100%", position: "absolute" }}
      />
    </div>
  );
};

export { Embed };
