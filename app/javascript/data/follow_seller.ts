import typia from "typia";

import { assertResponseError, request } from "$app/utils/request";

type FollowResponse = { success: true; message: string } | { success: false; message?: string };

export const followSeller = async (
  email: string,
  seller_id: string,
  // The CAPTCHA token, for sellers whose subscribe form requires one. Sent under
  // the name Google's verification API expects, which is also what the server
  // reads it from.
  recaptchaResponse: string | null = null,
): Promise<FollowResponse> => {
  try {
    const response = await request({
      method: "POST",
      accept: "json",
      url: Routes.follow_user_path(),
      data: { email, seller_id, "g-recaptcha-response": recaptchaResponse },
    });
    return typia.assert<FollowResponse>(await response.json());
  } catch (e) {
    assertResponseError(e);
    return { success: false };
  }
};
