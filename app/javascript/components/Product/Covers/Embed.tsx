import * as React from "react";

import { AssetPreview } from "$app/parsers/product";

import { DEFAULT_IMAGE_WIDTH } from "./";

type Props = { cover: AssetPreview; dimensions: { width: number; height: number } | null };
const Embed = ({ cover, dimensions }: Props) => {
  const iframeRef = React.useRef<null | HTMLIFrameElement>(null);

  return (
    <div
      style={{
        flexGrow: 1,
        position: "relative",
        paddingBottom: `${dimensions === null ? 0 : (dimensions.height * 100) / dimensions.width}%`,
      }}
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
