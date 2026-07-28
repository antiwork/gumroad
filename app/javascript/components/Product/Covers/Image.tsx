import * as React from "react";

import { AssetPreview } from "$app/parsers/product";

import { DEFAULT_IMAGE_WIDTH } from "./";

type Props = {
  cover: AssetPreview;
  dimensions: { height: number; width: number } | null;
  // See Covers/Video: `max-h-full` only bounds anything inside a frame with a definite
  // height, and only a shaped frame has one.
  frameIsShaped: boolean;
};
const Image = ({ cover, dimensions, frameIsShaped }: Props) => (
  <img
    // `w-full` alone derives the height from the width, which overflows a frame whose
    // height is capped — a tall poster or phone screenshot would be cropped top and
    // bottom. Bounding the height too, with `object-contain`, lets the image shrink to
    // fit the frame in whichever axis runs out first while keeping its proportions.
    // Landscape covers are unaffected: their height was already the shorter side.
    className={frameIsShaped ? "max-h-full w-full object-contain" : "w-full"}
    src={dimensions == null || dimensions.width > DEFAULT_IMAGE_WIDTH ? cover.original_url : cover.url}
    itemProp="image"
  />
);

export { Image };
