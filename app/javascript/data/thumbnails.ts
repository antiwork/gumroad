import { cast } from "$app/utils/cast";
import { ResponseError, request } from "$app/utils/request";

export type Thumbnail = { guid: string; url: string };

export type ThumbnailPayload = { type: "file"; signedBlobId: string };

export const createThumbnail = async (permalink: string, thumbnailPayload: ThumbnailPayload): Promise<Thumbnail> => {
  const response = await request({
    method: "POST",
    accept: "json",
    url: Routes.link_thumbnails_path(permalink),
    data: {
      thumbnail: { signed_blob_id: thumbnailPayload.signedBlobId },
    },
  });

  const responseData = cast<{ success: true; thumbnail: Thumbnail } | { success: false; error: string } | null>(
    await response.json().catch(() => null),
  );

  if (response.ok && responseData?.success) return responseData.thumbnail;

  // The server's body names the actual reason ("Invalid signed_blob_id."), which tells the seller more
  // than the generic ResponseError default — fall back to that default only when there is no message.
  if (responseData && !responseData.success && responseData.error !== "") throw new ResponseError(responseData.error);

  throw new ResponseError();
};

export const deleteThumbnail = async (permalink: string, thumbnailId: string) => {
  const response = await request({
    method: "DELETE",
    accept: "json",
    url: Routes.link_thumbnail_path(permalink, thumbnailId),
  });

  if (response.ok) {
    const responseData = cast<{ success: true; thumbnail: Thumbnail } | { success: false }>(await response.json());
    if (responseData.success) return;
  }

  throw new ResponseError();
};
