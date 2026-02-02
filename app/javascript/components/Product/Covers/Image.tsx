import * as React from "react";

import { AssetPreview } from "$app/parsers/product";

import { DEFAULT_IMAGE_WIDTH } from "./";

type Props = { cover: AssetPreview; dimensions: { height: number; width: number } | null };
const Image = ({ cover, dimensions }: Props) => (
  <img
    className="w-full"
    src={dimensions == null || dimensions.width > DEFAULT_IMAGE_WIDTH ? cover.original_url : cover.url}
    itemProp="image"
  />
);

export { Image };
