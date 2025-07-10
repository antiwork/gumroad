import * as React from "react";

import { AssetPreview } from "$app/parsers/product";

import { DEFAULT_IMAGE_WIDTH } from "./";

type Props = {
  cover: AssetPreview;
  dimensions: { height: number; width: number } | null;
  fetchPriority?: "high" | "low" | "auto";
  loading?: "eager" | "lazy";
  alt?: string | undefined;
};
const Image = ({ cover, dimensions, alt, loading, fetchPriority = "auto" }: Props) => (
  <img
    className="preview"
    src={dimensions == null || dimensions.width > DEFAULT_IMAGE_WIDTH ? cover.original_url : cover.url}
    itemProp="image"
    style={{ maxWidth: "100%" }}
    alt={alt}
    fetchPriority={fetchPriority}
    loading={loading}
  />
);

export { Image };
