import * as React from "react";
import { cast } from "ts-safe-cast";

import { ProductNativeType } from "$app/parsers/product";
import FileUtils from "$app/utils/file";

const nativeTypeThumbnails = require.context("$assets/images/native_types/thumbnails/");

const isVideoFile = (url: string): boolean => {
  const extension = FileUtils.getFileExtension(url).toLowerCase();
  return extension === 'webm' || extension === 'mp4' || extension === 'mov';
};

export const Thumbnail = ({ url, nativeType }: { url: string | null; nativeType: ProductNativeType }) => {
  if (!url) {
    return <img src={cast(nativeTypeThumbnails(`./${nativeType}.svg`))} />;
  }

  if (isVideoFile(url)) {
    return (
      <video
        src={url}
        controls={false}
        muted
        loop
        autoPlay
        playsInline
        style={{ width: '100%', height: 'auto' }}
      />
    );
  }

  return <img src={url} />;
};
