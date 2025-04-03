import { cast } from "ts-safe-cast";

import { AssetPreview } from "$app/parsers/product";
import { ResponseError, request } from "$app/utils/request";

export type CoverPayload = { type: "file"; signedBlobId: string } | { type: "url"; url: string };

export const createCover = async (permalink: string, coverPayload: CoverPayload) => {
  const response = await request({
    method: "POST",
    accept: "json",
    url: Routes.link_asset_previews_path(permalink),
    data: {
      asset_preview:
        coverPayload.type === "file" ? { signed_blob_id: coverPayload.signedBlobId } : { url: coverPayload.url },
    },
  });

  if (response.ok) {
    const responseData = cast<{ success: true; asset_previews: AssetPreview[] } | { success: false; error: string }>(
      await response.json(),
    );
    if (responseData.success) return responseData.asset_previews;
    throw new ResponseError(responseData.error);
  }

  throw new ResponseError();
};

export const deleteCover = async (permalink: string, coverId: string) => {
  const response = await request({
    method: "DELETE",
    accept: "json",
    url: Routes.link_asset_preview_path(permalink, coverId),
  });

  if (response.ok) {
    const responseData = cast<{ success: true; asset_previews: AssetPreview[] } | { success: false }>(
      await response.json(),
    );
    if (responseData.success) return responseData.asset_previews;
  }

  throw new ResponseError();
};
