import * as React from "react";
import { cast } from "ts-safe-cast";

import { ProductNativeType } from "$app/parsers/product";

const nativeTypeThumbnails = require.context("$assets/images/native_types/thumbnails/");

export const Thumbnail = ({
  url,
  nativeType,
  eager,
}: {
  url: string | null;
  nativeType: ProductNativeType;
  eager?: boolean | undefined;
}) => {
  const commonProps: React.ImgHTMLAttributes<HTMLImageElement> = {
    ...(eager == null
      ? {}
      : {
          fetchpriority: eager ? "high" : "auto",
          loading: eager ? ("eager" as const) : ("lazy" as const),
        }),
  };
  return url ? (
    <img src={url} {...commonProps} />
  ) : (
    <img src={cast(nativeTypeThumbnails(`./${nativeType}.svg`))} {...commonProps} />
  );
};
