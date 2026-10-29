import { cast } from "$app/utils/cast";
import { request, ResponseError } from "$app/utils/request";

// Starts the product's waitlist email, or finds the one already started, and returns where to edit it.
export const startWaitlistEmail = async (productPermalink: string) => {
  const response = await request({
    url: Routes.product_waitlist_email_path(productPermalink, "json"),
    method: "POST",
    accept: "json",
  });
  const json = cast<{ edit_url: string } | { error?: string }>(await response.json());
  if (!response.ok || !("edit_url" in json)) throw new ResponseError("error" in json ? json.error : undefined);
  return json.edit_url;
};
