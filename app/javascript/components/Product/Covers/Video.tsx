import * as React from "react";

import { AssetPreview } from "$app/parsers/product";
import { JWPlayerOptions, createJWPlayer } from "$app/utils/jwPlayer";

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
      playlist: [{ sources: [{ file: url, type: cover.filetype?.toLowerCase() }] }],
    };
    if (dimensions != null) {
      options.height = `${dimensions.height}px`;
      options.width = `${dimensions.width}px`;
    }

    void createJWPlayer(id, options);
  }, [id]);

  return (
    <div
      onClick={(e) => e.preventDefault()}
      style={{
        flexGrow: 1,
        position: "relative",
        paddingBottom: `${dimensions === null ? 0 : (dimensions.height * 100) / dimensions.width}%`,
      }}
    >
      <div id={id} />
    </div>
  );
};

export { Video };
