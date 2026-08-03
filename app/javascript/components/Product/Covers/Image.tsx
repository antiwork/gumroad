import * as React from "react";

import { AssetPreview } from "$app/parsers/product";

import { DEFAULT_IMAGE_WIDTH } from "./";

type Props = {
  cover: AssetPreview;
  dimensions: { height: number; width: number } | null;
  // See Covers/Video: `max-h-full` only bounds anything inside a frame with a definite
  // height, and only a shaped frame has one.
  frameIsShaped: boolean;
  productName?: string | undefined;
};
const Image = ({ cover, dimensions, frameIsShaped, productName }: Props) => (
  <img
    // `w-full` alone derives the height from the width, which overflows a frame whose
    // height is capped — a tall poster or phone screenshot would be cropped top and
    // bottom. Bounding the height too, with `object-contain`, lets the image shrink to
    // fit the frame in whichever axis runs out first while keeping its proportions.
    // Landscape covers are unaffected: their height was already the shorter side.
    className={frameIsShaped ? "max-h-full w-full object-contain" : "w-full"}
    src={dimensions == null || dimensions.width > DEFAULT_IMAGE_WIDTH ? cover.original_url : cover.url}
    // Unlike a thumbnail, a product-page cover is the primary content rather than decoration
    // beside a heading, so it carries the name. Falls back to empty where there is no product
    // context to name — the editor preview — because an unnamed img is announced by its filename.
    alt={productName ?? ""}
    itemProp="image"
  />
);

export { Image };
