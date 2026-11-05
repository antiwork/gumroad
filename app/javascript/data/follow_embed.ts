import { readJson, request } from "$app/utils/request";

export const followFromEmbed = async (sellerId: string, email: string, productId?: string) => {
  const response = await request({
    url: Routes.follow_user_from_embed_form_path(),
    method: "POST",
    accept: "json",
    data: { seller_id: sellerId, email, ...(productId ? { product_id: productId } : {}) },
  });
  return readJson<{ message: string }>(response);
};
