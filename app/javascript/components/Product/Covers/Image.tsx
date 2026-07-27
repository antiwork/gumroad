import * as React from "react";

import { AssetPreview } from "$app/parsers/product";

import { DEFAULT_IMAGE_WIDTH } from "./";

type Props = { cover: AssetPreview; dimensions: { height: number; width: number } | null };
const Image = ({ cover, dimensions }: Props) => (
  <img
    // `w-full` alone derives the height from the width, which overflows a frame whose
    // height is capped — a tall poster or phone screenshot would be cropped top and
    // bottom. Bounding the height too, with `object-contain`, lets the image shrink to
    // fit the frame in whichever axis runs out first while keeping its proportions.
    // Landscape covers are unaffected: their height was already the shorter side.
    className="max-h-full w-full object-contain"
    src={dimensions == null || dimensions.width > DEFAULT_IMAGE_WIDTH ? cover.original_url : cover.url}
    itemProp="image"
  />
);

export { Image };
