import * as React from "react";

import useLazyLoadingProps from "$app/hooks/useLazyLoadingProps";
import { ProductNativeType } from "$app/parsers/product";

const rawThumbnails = import.meta.glob<string>("$assets/images/native_types/thumbnails/*", {
  eager: true,
  query: "?url",
  import: "default",
});
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

  // Decorative in every current call site: a thumbnail always sits beside a heading or link text
  // that already names the product, so describing it again makes a screen reader announce the title
  // twice per row. `alt=""` is what removes it from the accessibility tree — an img with no `alt`
  // attribute at all is announced by its filename instead, which is the bug this replaces.
  return url ? (
    <img src={url} alt="" {...lazyLoadingProps} className={className} />
  ) : (
    <img src={nativeTypeThumbnails[`./${nativeType}.svg`]} alt="" {...lazyLoadingProps} className={className} />
  );
};
