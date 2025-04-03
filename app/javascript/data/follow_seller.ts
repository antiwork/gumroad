import { cast } from "ts-safe-cast";

import { assertResponseError, request } from "$app/utils/request";

type FollowResponse = { success: true; message: string } | { success: false };

export const followSeller = async (email: string, seller_id: string): Promise<FollowResponse> => {
  try {
    const response = await request({
      method: "POST",
      accept: "json",
      url: Routes.follow_user_path(),
      data: { email, seller_id },
    });
    return cast<FollowResponse>(await response.json());
  } catch (e) {
    assertResponseError(e);
    return { success: false };
  }
};
