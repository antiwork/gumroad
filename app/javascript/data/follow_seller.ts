import typia from "typia";

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
    return typia.assert<FollowResponse>(await response.json());
  } catch (e) {
    assertResponseError(e);
    return { success: false };
  }
};
