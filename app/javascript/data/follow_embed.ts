import { request, ResponseError } from "$app/utils/request";

export const followFromEmbed = async (sellerId: string, email: string) => {
  const response = await request({
    url: Routes.follow_user_from_embed_form_path(),
    method: "POST",
    accept: "json",
    data: { seller_id: sellerId, email },
  });
  if (!response.ok) throw new ResponseError();
};
