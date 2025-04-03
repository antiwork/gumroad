import { cast } from "ts-safe-cast";

import { request, ResponseError } from "$app/utils/request";

type TogglePublishStateResponse = { success: true } | { success: false; error_message: string };

export async function setProductPublished(id: string, publish: boolean) {
  const response = await request({
    url: publish ? Routes.publish_link_path(id) : Routes.unpublish_link_path(id),
    method: "POST",
    accept: "json",
  });
  const responseData = cast<TogglePublishStateResponse>(await response.json());
  if (!responseData.success) throw new ResponseError(responseData.error_message);
}
