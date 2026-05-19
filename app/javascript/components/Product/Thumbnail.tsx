import * as React from "react";

import useLazyLoadingProps from "$app/hooks/useLazyLoadingProps";
import { ProductNativeType } from "$app/parsers/product";

const rawThumbnails = import.meta.glob("$assets/images/native_types/thumbnails/*", {
  eager: true,
  query: "?url",
  import: "default",
}) as Record<string, string>;
const nativeTypeThumbnails = Object.fromEntries(
  Object.entries(rawThumbnails).map(([key, value]) => [`./${key.split("/").pop()}`, value]),
);

export const Thumbnail = ({
  url,
  nativeType,
  eager,
  className,
}: {
  url: string | null;
  nativeType: ProductNativeType;
  eager?: boolean | undefined;
  className?: string;
}) => {
  const lazyLoadingProps = useLazyLoadingProps({ eager });

  return url ? (
    <img src={url} {...lazyLoadingProps} className={className} />
  ) : (
    <img src={nativeTypeThumbnails[`./${nativeType}.svg`]} {...lazyLoadingProps} className={className} />
  );
};
