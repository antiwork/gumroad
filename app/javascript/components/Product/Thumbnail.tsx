import * as React from "react";
import { cast } from "ts-safe-cast";

import { ProductNativeType } from "$app/parsers/product";

const nativeTypeThumbnails = require.context("$assets/images/native_types/thumbnails/");

export const Thumbnail = ({
  url,
  nativeType,
  loading,
  fetchPriority = "auto",
}: {
  url: string | null;
  nativeType: ProductNativeType;
  loading?: "eager" | "lazy";
  fetchPriority?: "high" | "low" | "auto";
}) =>
  url ? (
    // eslint-disable-next-line react/no-unknown-property
    <img src={url} loading={loading} fetchpriority={fetchPriority} />
  ) : (
    // eslint-disable-next-line react/no-unknown-property
    <img src={cast(nativeTypeThumbnails(`./${nativeType}.svg`))} loading={loading} fetchpriority={fetchPriority} />
  );
