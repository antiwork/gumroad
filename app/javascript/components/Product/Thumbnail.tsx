import * as React from "react";
import { cast } from "ts-safe-cast";

import { ProductNativeType } from "$app/parsers/product";

import { useLoggedInUser } from "$app/components/LoggedInUser";

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
  const loggedInUser = useLoggedInUser();
  const commonProps: React.ImgHTMLAttributes<HTMLImageElement> = {
    ...(eager == null || !loggedInUser?.lazyLoadOffscreenDiscoverImages
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
