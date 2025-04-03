import * as React from "react";
import { cast } from "ts-safe-cast";

import { ProductNativeType } from "$app/parsers/product";

const nativeTypeThumbnails = require.context("$assets/images/native_types/thumbnails/");

export const Thumbnail = ({ url, nativeType }: { url: string | null; nativeType: ProductNativeType }) =>
  url ? <img src={url} /> : <img src={cast(nativeTypeThumbnails(`./${nativeType}.svg`))} />;
