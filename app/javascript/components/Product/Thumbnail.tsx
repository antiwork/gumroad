import * as React from "react";
import { cast } from "ts-safe-cast";

import useLazyLoadingProps from "$app/hooks/useLazyLoadingProps";
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
  const lazyLoadingProps = useLazyLoadingProps({ eager });

  return url ? (
    <img src={url} {...lazyLoadingProps} />
  ) : (
    <img src={cast(nativeTypeThumbnails(`./${nativeType}.svg`))} {...lazyLoadingProps} />
  );
};
