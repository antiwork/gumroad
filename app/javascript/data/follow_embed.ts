import { cast } from "$app/utils/cast";
import { readJson, request, ResponseError } from "$app/utils/request";

// The server refused the follow and said why, such as where the visitor can sign up instead.
export class FollowFromEmbedError extends ResponseError {}

export const followFromEmbed = async (sellerId: string, email: string, productId?: string) => {
  const response = await request({
    url: Routes.follow_user_from_embed_form_path(),
    method: "POST",
    accept: "json",
    data: { seller_id: sellerId, email, ...(productId ? { product_id: productId } : {}) },
  });
  if (!response.ok) {
    const body = cast<{ message?: unknown } | null>(await response.json().catch(() => null));
    if (typeof body?.message === "string" && body.message !== "") throw new FollowFromEmbedError(body.message);
  }
  return readJson<{ message: string }>(response);
};
